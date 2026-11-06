import 'dart:async';

import 'cache_codec.dart';
import 'cache_endpoint.dart';
import 'cache_entry.dart';
import 'cache_exception.dart';
import 'cache_logger.dart';
import 'cache_metrics.dart';
import 'cache_policy.dart';
import 'cache_scope.dart';
import 'cache_state.dart';
import 'cache_store.dart';
import 'memory_cache_store.dart';
import 'persisted_record.dart';
import 'persistent_store.dart';
import 'result.dart';
import 'retry_options.dart';
import 'token_keeper.dart';

/// A function that produces a fresh value asynchronously.
///
/// Fetchers should return a [Result] rather than throwing — but raised
/// exceptions are caught and converted to a [Failure] regardless.
typedef Fetcher<T> = Future<Result<T>> Function();

/// Stores a cached [Failure] alongside its TTL bookkeeping.
class _CachedFailure {
  _CachedFailure({required this.failure, required this.createdAt, this.ttl});

  final Failure<dynamic> failure;
  final DateTime createdAt;
  final Duration? ttl;

  bool isExpiredAt(DateTime now) {
    if (ttl == null) return false;
    return !now.isBefore(createdAt.add(ttl!));
  }
}

/// Bookkeeping for a key's scope — global / session / user(uid).
class _ScopeMeta {
  const _ScopeMeta(this.scope, [this.userId]);

  final CacheScope scope;
  final String? userId;
}

/// The unified cache + data orchestration entry point.
///
/// One [Cache] manages a keyed [CacheStore], coordinates concurrent fetches
/// (single-flight), broadcasts updates to [watch] subscribers, understands
/// lifecycle scopes (v1.1.0), and — when given a [PersistentStore] plus
/// codecs — survives restarts via write-through persistence and [hydrate]
/// (v1.2.0).
class Cache {
  Cache({
    CacheStore? store,
    Duration? defaultTtl,
    DateTime Function()? clock,
    CacheLogger? logger,
    RetryOptions? retryOptions,
    bool cacheFailures = false,
    TokenKeeperAdapter? tokenKeeper,
    PersistentStore? persistentStore,
    int? maxEntries,
  })  : assert(maxEntries == null || maxEntries > 0,
            'maxEntries must be positive'),
        _maxEntries = maxEntries,
        _store = store ?? MemoryCacheStore(),
        _defaultTtl = defaultTtl,
        _now = clock ?? DateTime.now,
        _logger = logger ?? const CacheLogger(),
        _defaultRetryOptions = retryOptions ?? RetryOptions.noRetry,
        _defaultCacheFailures = cacheFailures,
        _tokenKeeper = tokenKeeper,
        _persistentStore = persistentStore;

  final CacheStore _store;
  final Duration? _defaultTtl;
  final DateTime Function() _now;
  final CacheLogger _logger;
  final RetryOptions _defaultRetryOptions;
  final bool _defaultCacheFailures;
  final TokenKeeperAdapter? _tokenKeeper;
  final PersistentStore? _persistentStore;
  final int? _maxEntries;

  final Map<String, Future<Result<dynamic>>> _inflight = {};
  final Map<String, StreamController<Result<dynamic>>> _watchers = {};

  // v1.0.2 — separate store for cached failures.
  final Map<String, _CachedFailure> _failureCache = {};

  // v1.1.0 — scope metadata per key. Absent => global.
  final Map<String, _ScopeMeta> _scopes = {};
  String? _activeUserId;

  // v1.2.0 — persistence codecs (keyed by key-prefix) + in-flight writes.
  final Map<String, CacheCodec<dynamic>> _codecs = {};
  final Set<Future<void>> _pendingPersistence = {};

  // v2.1.0 — tag index (key -> tags) and LRU order (least recent first).
  final Map<String, Set<String>> _tags = {};
  final Set<String> _lru = <String>{};

  // v1.2.0 — lifetime metrics.
  int _hits = 0;
  int _misses = 0;
  int _writes = 0;
  int _refreshes = 0;
  int _errors = 0;
  int _evictions = 0;

  /// The currently active user id, or `null` if no user is signed in.
  /// Set via [setActiveUser]. Affects [CacheScope.user] entries.
  String? get activeUserId => _activeUserId;

  /// The token keeper passed at construction, or `null` if none was provided.
  /// Used by [getAuthenticated].
  TokenKeeperAdapter? get tokenKeeper => _tokenKeeper;

  /// The LRU capacity passed to [Cache.new], or `null` when unbounded.
  /// New in v2.1.0.
  int? get maxEntries => _maxEntries;

  /// `true` if this cache was configured with a [PersistentStore].
  bool get isPersistent => _persistentStore != null;

  /// An immutable snapshot of the cache's lifetime counters. New in v1.2.0.
  CacheMetrics get metrics => CacheMetrics(
        hits: _hits,
        misses: _misses,
        writes: _writes,
        refreshes: _refreshes,
        errors: _errors,
        evictions: _evictions,
      );

  /// Resets every [metrics] counter back to zero. New in v1.2.0.
  void resetMetrics() {
    _hits = _misses = _writes = _refreshes = _errors = _evictions = 0;
  }

  /// Registers a [CacheCodec] used to persist and restore entries whose key
  /// starts with [keyPrefix].
  ///
  /// When multiple prefixes match a key, the longest wins. Only keys with a
  /// registered codec are written to the [PersistentStore]; everything else
  /// stays memory-only.
  ///
  /// New in v1.2.0.
  void registerCodec<T>(String keyPrefix, CacheCodec<T> codec) {
    _codecs[keyPrefix] = CacheCodec<dynamic>(
      encode: (value) => codec.encode(value as T),
      decode: (json) => codec.decode(json) as dynamic,
    );
  }

  /// Restores entries from the [PersistentStore] into the in-memory store.
  ///
  /// Call once at startup (e.g. before `runApp`) to make cached data available
  /// immediately. Expired records are skipped and pruned from disk. Records
  /// without a matching registered codec are left untouched on disk and not
  /// loaded. Returns the number of entries restored.
  ///
  /// No-op (returns 0) when no [PersistentStore] is configured.
  ///
  /// New in v1.2.0.
  Future<int> hydrate() async {
    final store = _persistentStore;
    if (store == null) return 0;

    final records = await store.loadAll();
    final now = _now();
    var restored = 0;

    for (final record in records) {
      final codec = _codecFor(record.key);
      if (codec == null) continue;

      final createdAt = DateTime.fromMillisecondsSinceEpoch(record.createdAtMs);
      final ttl =
          record.ttlMs == null ? null : Duration(milliseconds: record.ttlMs!);
      final entry = CacheEntry<dynamic>(
        value: codec.decode(record.value),
        createdAt: createdAt,
        ttl: ttl,
      );

      if (entry.isExpiredAt(now)) {
        _track(store.remove(record.key));
        continue;
      }

      _store.write(record.key, entry);
      _touchLru(record.key);
      final scope = _scopeFromName(record.scope);
      if (scope != CacheScope.global) {
        _scopes[record.key] = _ScopeMeta(scope, record.userId);
      }
      restored++;
    }
    _evictOverflow();
    return restored;
  }

  /// Awaits all outstanding write-through persistence operations.
  ///
  /// Persistence is fire-and-forget by default so it never blocks the read
  /// path; call [flush] when you need a durability checkpoint (e.g. before the
  /// app backgrounds, or in a test). New in v1.2.0.
  Future<void> flush() => Future.wait(_pendingPersistence.toList());

  /// Reads from / writes to the cache for [key] according to [policy].
  ///
  /// [fetch] is the source of truth used when the policy needs fresh data.
  ///
  /// **v1.0.2 options**
  /// - [retryOptions]: overrides the cache-wide default for this call.
  /// - [cacheFailures]: overrides the cache-wide default for this call.
  ///   When `true`, a failure returned after exhausting retries is cached so
  ///   the next `cacheFirst` / `cacheOnly` lookup returns it immediately.
  /// - [alwaysRevalidate]: only relevant for [CachePolicy.staleWhileRevalidate].
  ///   When `false` (default) a background refresh is only kicked off when the
  ///   entry is stale; when `true` the pre-v1.0.2 behaviour is restored
  ///   (revalidate even if the entry is still fresh).
  ///
  /// **v1.1.0 options**
  /// - [scope]: lifecycle of the entry. Defaults to [CacheScope.global].
  ///   Use [CacheScope.session] for data that should disappear on logout and
  ///   [CacheScope.user] for data tied to the active user. User-scoped reads
  ///   throw a [StateError] if no active user is set.
  Future<Result<T>> get<T>({
    required String key,
    required Fetcher<T> fetch,
    CachePolicy policy = CachePolicy.cacheFirst,
    Duration? ttl,
    RetryOptions? retryOptions,
    bool? cacheFailures,
    bool alwaysRevalidate = false,
    CacheScope scope = CacheScope.global,
    Set<String> tags = const {},
  }) async {
    _ensureScopeUsable(scope);
    final effectiveTtl = ttl ?? _defaultTtl;
    final effectiveRetry = retryOptions ?? _defaultRetryOptions;
    final effectiveCacheFailures = cacheFailures ?? _defaultCacheFailures;
    final now = _now();

    switch (policy) {
      case CachePolicy.cacheOnly:
        final entry = _store.read(key);
        if (entry == null || entry.isExpiredAt(now)) {
          final cached = _failureCache[key];
          if (cached != null && !cached.isExpiredAt(now)) {
            return _castResult<T>(cached.failure);
          }
          _miss(key);
          return entry == null
              ? Failure<T>(CacheMissException(key))
              : Failure<T>(CacheExpiredException(key));
        }
        _hit(key);
        return Success<T>(entry.value as T);

      case CachePolicy.networkOnly:
        return _runFetch<T>(
          key,
          fetch,
          persist: false,
          ttl: effectiveTtl,
          source: RefreshSource.policy,
          retryOptions: effectiveRetry,
          cacheFailures: false,
          scope: scope,
          tags: tags,
        );

      case CachePolicy.cacheFirst:
        final entry = _store.read(key);
        if (entry != null && !entry.isExpiredAt(now)) {
          _hit(key);
          return Success<T>(entry.value as T);
        }
        final cached = _failureCache[key];
        if (cached != null && !cached.isExpiredAt(now)) {
          return _castResult<T>(cached.failure);
        }
        _miss(key);
        return _runFetch<T>(
          key,
          fetch,
          persist: true,
          ttl: effectiveTtl,
          source: RefreshSource.cacheMiss,
          retryOptions: effectiveRetry,
          cacheFailures: effectiveCacheFailures,
          scope: scope,
          tags: tags,
        );

      case CachePolicy.networkFirst:
        final fresh = await _runFetch<T>(
          key,
          fetch,
          persist: true,
          ttl: effectiveTtl,
          source: RefreshSource.policy,
          retryOptions: effectiveRetry,
          cacheFailures: effectiveCacheFailures,
          scope: scope,
          tags: tags,
        );
        if (fresh.isSuccess) return fresh;
        final entry = _store.read(key);
        if (entry != null) {
          _hit(key);
          return Success<T>(entry.value as T);
        }
        final cachedFailure = _failureCache[key];
        if (cachedFailure != null && !cachedFailure.isExpiredAt(now)) {
          return _castResult<T>(cachedFailure.failure);
        }
        return fresh;

      case CachePolicy.staleWhileRevalidate:
        final entry = _store.read(key);
        if (entry != null) {
          _hit(key);
          final isStale = entry.isExpiredAt(now);
          if ((isStale || alwaysRevalidate) && !_inflight.containsKey(key)) {
            unawaited(
              _runFetch<T>(
                key,
                fetch,
                persist: true,
                ttl: effectiveTtl,
                source: RefreshSource.background,
                retryOptions: effectiveRetry,
                cacheFailures: effectiveCacheFailures,
                scope: scope,
                tags: tags,
              ),
            );
          }
          return Success<T>(entry.value as T);
        }
        _miss(key);
        return _runFetch<T>(
          key,
          fetch,
          persist: true,
          ttl: effectiveTtl,
          source: RefreshSource.cacheMiss,
          retryOptions: effectiveRetry,
          cacheFailures: effectiveCacheFailures,
          scope: scope,
          tags: tags,
        );
    }
  }

  /// Like [get] but routes the fetch through the configured
  /// [TokenKeeperAdapter] so the fetcher receives a valid access token.
  ///
  /// Equivalent to:
  /// ```dart
  /// cache.get(
  ///   fetch: () => tokenKeeper.withValidToken(fetchWithToken),
  ///   ...
  /// );
  /// ```
  ///
  /// Throws [StateError] if no [TokenKeeperAdapter] was passed to [Cache.new].
  /// Defaults to [CacheScope.user] since authenticated data is almost always
  /// per-user — override explicitly for shared resources.
  ///
  /// New in v1.1.0.
  Future<Result<T>> getAuthenticated<T>({
    required String key,
    required AuthenticatedAction<T> fetch,
    CachePolicy policy = CachePolicy.cacheFirst,
    Duration? ttl,
    RetryOptions? retryOptions,
    bool? cacheFailures,
    bool alwaysRevalidate = false,
    CacheScope scope = CacheScope.user,
    Set<String> tags = const {},
  }) {
    final keeper = _tokenKeeper;
    if (keeper == null) {
      throw StateError(
        'getAuthenticated requires a TokenKeeperAdapter. '
        'Pass one to Cache(tokenKeeper: ...).',
      );
    }
    return get<T>(
      key: key,
      fetch: () => keeper.withValidToken<T>(fetch),
      policy: policy,
      ttl: ttl,
      retryOptions: retryOptions,
      cacheFailures: cacheFailures,
      alwaysRevalidate: alwaysRevalidate,
      scope: scope,
      tags: tags,
    );
  }

  /// Forces a fetch, writes to the cache, and notifies watchers.
  Future<Result<T>> refresh<T>({
    required String key,
    required Fetcher<T> fetch,
    Duration? ttl,
    RetryOptions? retryOptions,
    bool? cacheFailures,
    CacheScope scope = CacheScope.global,
    Set<String> tags = const {},
  }) {
    _ensureScopeUsable(scope);
    return _runFetch<T>(
      key,
      fetch,
      persist: true,
      ttl: ttl ?? _defaultTtl,
      source: RefreshSource.refresh,
      retryOptions: retryOptions ?? _defaultRetryOptions,
      cacheFailures: cacheFailures ?? _defaultCacheFailures,
      scope: scope,
      tags: tags,
    );
  }

  /// Like [refresh] but framed as a warmup: fetches and caches eagerly so a
  /// subsequent [get] is an instant cache hit.
  Future<Result<T>> prefetch<T>({
    required String key,
    required Fetcher<T> fetch,
    Duration? ttl,
    RetryOptions? retryOptions,
    bool? cacheFailures,
    CacheScope scope = CacheScope.global,
    Set<String> tags = const {},
  }) {
    _ensureScopeUsable(scope);
    return _runFetch<T>(
      key,
      fetch,
      persist: true,
      ttl: ttl ?? _defaultTtl,
      source: RefreshSource.prefetch,
      retryOptions: retryOptions ?? _defaultRetryOptions,
      cacheFailures: cacheFailures ?? _defaultCacheFailures,
      scope: scope,
      tags: tags,
    );
  }

  /// Drops the success and failure entries for [key] from memory and (if
  /// configured) the [PersistentStore].
  void invalidate(String key) {
    _remove(key);
    _logger.onInvalidate(key);
  }

  void _remove(String key) {
    _store.delete(key);
    _failureCache.remove(key);
    _scopes.remove(key);
    _tags.remove(key);
    _lru.remove(key);
    _removeFromDisk(key);
  }

  /// Drops every entry from the store, the failure cache, and (if configured)
  /// the [PersistentStore].
  void clear() {
    _store.clear();
    _failureCache.clear();
    _scopes.clear();
    _tags.clear();
    _lru.clear();
    final store = _persistentStore;
    if (store != null) _track(store.clear());
    _logger.onClear();
  }

  /// Subscribes to updates for [key].
  ///
  /// The returned stream is broadcast: emissions happen whenever the cache is
  /// updated for [key] (via [get], [refresh], [prefetch], or a background
  /// refresh from [CachePolicy.staleWhileRevalidate]). Subscribers do not
  /// receive the current cached value on subscription — call [get] (or
  /// [peek]) for that.
  ///
  /// With [emitCurrent] (v2.1.0), a subscriber first receives the value
  /// currently cached for [key] — fresh or stale — as a [Success], then live
  /// updates. Nothing extra is emitted when [key] is absent.
  Stream<Result<T>> watch<T>(String key, {bool emitCurrent = false}) {
    final controller = _watchers.putIfAbsent(
      key,
      () => StreamController<Result<dynamic>>.broadcast(),
    );
    final live = controller.stream.map(_castResult<T>);
    if (!emitCurrent) return live;
    return Stream<Result<T>>.multi((out) {
      final entry = _store.read(key);
      if (entry != null) out.add(Success<T>(entry.value as T));
      final sub = live.listen(out.add, onError: out.addError, onDone: out.close);
      out.onCancel = sub.cancel;
    }, isBroadcast: true);
  }

  /// Synchronous, non-fetching read of the cache.
  ///
  /// Returns `null` if [key] is absent or (when [allowExpired] is `false`)
  /// expired. Use this to seed UI state from cache without triggering a fetch.
  T? peek<T>(String key, {bool allowExpired = false}) {
    final entry = _store.read(key);
    if (entry == null) return null;
    if (!allowExpired && entry.isExpiredAt(_now())) return null;
    _touchLru(key);
    return entry.value as T;
  }

  /// Returns a [CacheState] snapshot describing what the success cache
  /// currently holds for [key]. Never triggers a fetch.
  CacheState<T> inspect<T>(String key) {
    final entry = _store.read(key);
    final now = _now();
    if (entry == null) {
      return CacheState<T>(key: key, now: now);
    }
    return CacheState<T>(
      key: key,
      now: now,
      value: entry.value as T,
      createdAt: entry.createdAt,
      ttl: entry.ttl,
    );
  }

  /// `true` when [key] has a non-expired cached failure.
  ///
  /// Useful for showing an error state in the UI without triggering a fetch.
  /// New in v1.0.2.
  bool hasCachedFailure(String key) {
    final cached = _failureCache[key];
    return cached != null && !cached.isExpiredAt(_now());
  }

  /// Returns the [CacheScope] recorded for [key], or [CacheScope.global] when
  /// the key is untracked or absent. New in v1.1.0.
  CacheScope scopeOf(String key) => _scopes[key]?.scope ?? CacheScope.global;

  /// Changes the active user id and clears entries belonging to other users.
  ///
  /// Passing `null` is equivalent to a logout for user-scoped data — see
  /// [endSession] when you also want to drop [CacheScope.session] entries.
  ///
  /// No-op when [userId] equals [activeUserId].
  ///
  /// New in v1.1.0.
  void setActiveUser(String? userId) {
    if (userId == _activeUserId) return;
    _activeUserId = userId;

    // Clear user-scoped entries that don't belong to the new user. This also
    // covers entries restored by [hydrate] for a different account.
    final removed = _keysFor(
      (meta) => meta.scope == CacheScope.user && meta.userId != userId,
    );
    _invalidateKeys(removed);
    if (removed.isNotEmpty) {
      _logger.onScopeCleared('setActiveUser', removed);
    }
  }

  /// Drops [CacheScope.session] and [CacheScope.user] entries, and clears
  /// [activeUserId].
  ///
  /// Call this from your logout flow. Global entries are kept.
  ///
  /// New in v1.1.0.
  void endSession() {
    final removed = _keysFor(
      (meta) =>
          meta.scope == CacheScope.session || meta.scope == CacheScope.user,
    );
    _invalidateKeys(removed);
    _activeUserId = null;
    if (removed.isNotEmpty) {
      _logger.onScopeCleared('endSession', removed);
    }
  }

  /// Drops every entry recorded with [scope]. Use to wipe a specific
  /// lifecycle bucket without touching the others.
  ///
  /// **Note:** [CacheScope.global] entries are not tracked in the scope index
  /// (the absence of a scope record *is* the global scope), so passing
  /// `CacheScope.global` is a no-op. Use [clear] to drop globals too.
  ///
  /// New in v1.1.0.
  void clearScope(CacheScope scope) {
    final removed = _keysFor((meta) => meta.scope == scope);
    _invalidateKeys(removed);
    if (removed.isNotEmpty) {
      _logger.onScopeCleared('clearScope:${scope.name}', removed);
    }
  }

  // ── v2.0.0 — unified data engine ───────────────────────────────────────────

  /// Number of entries currently held by the in-memory store (fresh or stale).
  ///
  /// New in v2.0.0.
  int get size => _store.keys().length;

  /// All keys currently held by the in-memory store.
  ///
  /// New in v2.0.0.
  Iterable<String> get allKeys => _store.keys();

  /// `true` if [key] has any entry in the store, even an expired one.
  ///
  /// New in v2.0.0.
  bool contains(String key) => _store.contains(key);

  /// Resets an entry's `createdAt` to *now*, extending its TTL window without
  /// re-fetching. Use when you have out-of-band evidence the entry is still
  /// valid (e.g. a websocket "no changes" ping). Optionally swap the TTL too.
  ///
  /// No-op when [key] is absent.
  ///
  /// New in v2.0.0.
  void touch(String key, {Duration? ttl}) {
    final entry = _store.read(key);
    if (entry == null) return;
    final refreshed = CacheEntry<dynamic>(
      value: entry.value,
      createdAt: _now(),
      ttl: ttl ?? entry.ttl,
    );
    _store.write(key, refreshed);
    _persist(key, refreshed, scopeOf(key));
  }

  /// A snapshot of every cache entry as a `Map<key, CacheState>`. Doesn't
  /// trigger any fetch. Handy for dev tooling and tests.
  ///
  /// New in v2.0.0.
  Map<String, CacheState<dynamic>> snapshot() {
    final out = <String, CacheState<dynamic>>{};
    final now = _now();
    for (final key in _store.keys()) {
      final entry = _store.read(key);
      if (entry == null) continue;
      out[key] = CacheState<dynamic>(
        key: key,
        now: now,
        value: entry.value,
        createdAt: entry.createdAt,
        ttl: entry.ttl,
      );
    }
    return out;
  }

  /// Human-readable dump of cache state — entries, scopes, freshness,
  /// metrics, and active user. Designed for `print(cache.debugDump())`.
  ///
  /// New in v2.0.0.
  String debugDump() {
    final buf = StringBuffer()
      ..writeln('Cache(size=$size, ${metrics.toString()})')
      ..writeln('  activeUser=${_activeUserId ?? "<none>"}, '
          'persistent=$isPersistent, '
          'tokenKeeper=${_tokenKeeper != null}');
    final snap = snapshot();
    if (snap.isEmpty) {
      buf.writeln('  (no entries)');
    } else {
      for (final entry in snap.entries) {
        final s = entry.value;
        final scope = scopeOf(entry.key);
        final freshness = s.isFresh ? 'fresh' : 'stale';
        final ageS = s.age?.inMilliseconds;
        buf.writeln('  - ${entry.key.padRight(28)} '
            '$freshness  scope=${scope.name}  '
            'age=${ageS}ms  ttl=${s.ttl?.inMilliseconds ?? '∞'}ms');
      }
    }
    if (_failureCache.isNotEmpty) {
      buf.writeln('  cached-failures: ${_failureCache.keys.join(', ')}');
    }
    return buf.toString();
  }

  // ── v2.1.0 — direct writes & bulk invalidation ─────────────────────────────

  /// Writes [value] straight into the cache — no fetch. Use it to seed the
  /// cache or to apply an optimistic update. Notifies [watch] subscribers,
  /// persists (if configured), and clears any cached failure for [key].
  ///
  /// [ttl] defaults to the cache-wide default TTL.
  ///
  /// New in v2.1.0.
  void set<T>(
    String key,
    T value, {
    Duration? ttl,
    CacheScope scope = CacheScope.global,
    Set<String> tags = const {},
  }) {
    _ensureScopeUsable(scope);
    _write<T>(key, value, ttl: ttl ?? _defaultTtl, scope: scope, tags: tags);
  }

  /// Replaces the cached value for [key] with `transform(current)`.
  ///
  /// Keeps the entry's existing TTL and scope, but restarts its freshness
  /// window. Returns the new value, or `null` (and does nothing) when [key] is
  /// absent or expired — there is nothing to transform.
  ///
  /// New in v2.1.0.
  T? update<T>(String key, T Function(T current) transform) {
    final entry = _store.read(key);
    if (entry == null || entry.isExpiredAt(_now())) return null;
    final next = transform(entry.value as T);
    _write<T>(
      key,
      next,
      ttl: entry.ttl,
      scope: scopeOf(key),
      tags: _tags[key] ?? const {},
    );
    return next;
  }

  /// Invalidates every key for which [test] returns `true` and returns how
  /// many were dropped, e.g. `cache.invalidateWhere((k) => k.startsWith('user:'))`.
  ///
  /// New in v2.1.0.
  int invalidateWhere(bool Function(String key) test) {
    final keys = {..._store.keys(), ..._failureCache.keys}.where(test).toList();
    keys.forEach(invalidate);
    return keys.length;
  }

  /// Invalidates every entry written with [tag] (see the `tags` parameter of
  /// [get], [set], [refresh], [prefetch] and endpoints). Returns how many keys
  /// were dropped.
  ///
  /// Tags are in-memory only: entries restored by [hydrate] carry no tags.
  ///
  /// New in v2.1.0.
  int invalidateTag(String tag) =>
      invalidateWhere((key) => _tags[key]?.contains(tag) ?? false);

  /// The tags recorded for [key] (empty when untagged or absent).
  ///
  /// New in v2.1.0.
  Set<String> tagsOf(String key) => _tags[key] ?? const {};

  /// Builds a reusable, parameterised [CacheEndpoint] over this cache.
  ///
  /// The endpoint bundles a key-builder, fetcher, and policy so callers can
  /// just `await users(42)` instead of repeating `cache.get(...)` everywhere.
  ///
  /// New in v2.0.0.
  CacheEndpoint<P, T> endpoint<P, T>({
    required KeyBuilder<P> key,
    required EndpointFetcher<P, T> fetch,
    CachePolicy policy = CachePolicy.cacheFirst,
    Duration? ttl,
    CacheScope scope = CacheScope.global,
    Set<String> tags = const {},
    RetryOptions? retryOptions,
    bool? cacheFailures,
    bool alwaysRevalidate = false,
  }) =>
      CacheEndpoint<P, T>(
        cache: this,
        key: key,
        fetch: fetch,
        policy: policy,
        ttl: ttl,
        scope: scope,
        tags: tags,
        retryOptions: retryOptions,
        cacheFailures: cacheFailures,
        alwaysRevalidate: alwaysRevalidate,
      );

  /// Builds an [AuthenticatedCacheEndpoint] — like [endpoint] but routes the
  /// fetcher through the configured [TokenKeeperAdapter].
  ///
  /// Throws [StateError] if no [TokenKeeperAdapter] was passed to [Cache.new].
  ///
  /// New in v2.0.0.
  AuthenticatedCacheEndpoint<P, T> authenticatedEndpoint<P, T>({
    required KeyBuilder<P> key,
    required AuthEndpointFetcher<P, T> fetch,
    CachePolicy policy = CachePolicy.cacheFirst,
    Duration? ttl,
    CacheScope scope = CacheScope.user,
    Set<String> tags = const {},
    RetryOptions? retryOptions,
    bool? cacheFailures,
    bool alwaysRevalidate = false,
  }) {
    if (_tokenKeeper == null) {
      throw StateError(
        'authenticatedEndpoint requires a TokenKeeperAdapter. '
        'Pass one to Cache(tokenKeeper: ...).',
      );
    }
    return AuthenticatedCacheEndpoint<P, T>(
      cache: this,
      key: key,
      fetch: fetch,
      policy: policy,
      ttl: ttl,
      scope: scope,
      tags: tags,
      retryOptions: retryOptions,
      cacheFailures: cacheFailures,
      alwaysRevalidate: alwaysRevalidate,
    );
  }

  /// Combines the cached values for [keys] into a reactive stream.
  ///
  /// Emits the result of [combine] whenever any of the underlying keys
  /// updates. If any key currently holds a cached [Failure], the failure is
  /// propagated until that key reports a success again. The stream is
  /// single-subscription (call `.asBroadcastStream()` if you need multiple
  /// listeners); the initial value (if all keys have data) is emitted on the
  /// next microtask after `listen()`.
  ///
  /// New in v2.0.0.
  Stream<Result<R>> combineLatest<R>(
    List<String> keys,
    R Function(List<Object?> values) combine,
  ) {
    if (keys.isEmpty) {
      return Stream<Result<R>>.value(Success<R>(combine(const [])));
    }

    late StreamController<Result<R>> controller;
    final values = List<Object?>.filled(keys.length, null);
    final hasValue = List<bool>.filled(keys.length, false);
    final failures = List<Failure<dynamic>?>.filled(keys.length, null);
    final subs = <StreamSubscription<Result<dynamic>>>[];

    void emit() {
      if (controller.isClosed) return;
      for (final f in failures) {
        if (f != null) {
          controller.add(_castResult<R>(f));
          return;
        }
      }
      if (hasValue.every((b) => b)) {
        try {
          controller.add(Success<R>(combine(List.of(values))));
        } catch (e, st) {
          controller.add(Failure<R>(e, st));
        }
      }
    }

    controller = StreamController<Result<R>>(
      onListen: () {
        for (var i = 0; i < keys.length; i++) {
          final v = peek<dynamic>(keys[i]);
          if (v != null) {
            values[i] = v;
            hasValue[i] = true;
          }
        }
        for (var i = 0; i < keys.length; i++) {
          final idx = i;
          subs.add(
            watch<dynamic>(keys[i]).listen((r) {
              if (r is Success) {
                values[idx] = r.value;
                hasValue[idx] = true;
                failures[idx] = null;
              } else if (r is Failure) {
                failures[idx] = r;
              }
              emit();
            }),
          );
        }
        scheduleMicrotask(emit);
      },
      onCancel: () async {
        for (final s in subs) {
          await s.cancel();
        }
        subs.clear();
      },
    );
    return controller.stream;
  }

  /// Synchronous, non-fetching combined read. Returns `null` when any key is
  /// missing from the cache. Useful for seeding UI before subscribing to
  /// [combineLatest].
  ///
  /// New in v2.0.0.
  Result<R>? peekCombined<R>(
    List<String> keys,
    R Function(List<Object?> values) combine,
  ) {
    final values = <Object?>[];
    for (final key in keys) {
      final v = peek<dynamic>(key);
      if (v == null) return null;
      values.add(v);
    }
    try {
      return Success<R>(combine(values));
    } catch (e, st) {
      return Failure<R>(e, st);
    }
  }

  /// Awaits any pending persistence writes, then closes watcher streams.
  ///
  /// In v2.0.0 [dispose] flushes first so durability isn't lost when an app
  /// shuts down immediately after a write.
  Future<void> dispose() async {
    await flush();
    final controllers = List.of(_watchers.values);
    _watchers.clear();
    for (final c in controllers) {
      await c.close();
    }
  }

  // ── internal helpers ───────────────────────────────────────────────────────

  void _hit(String key) {
    _touchLru(key);
    _hits++;
    _logger.onHit(key);
  }

  void _miss(String key) {
    _misses++;
    _logger.onMiss(key);
  }

  void _ensureScopeUsable(CacheScope scope) {
    if (scope == CacheScope.user && _activeUserId == null) {
      throw StateError(
        'CacheScope.user requires an active user. '
        'Call cache.setActiveUser(userId) before using user-scoped entries.',
      );
    }
  }

  void _recordTags(String key, Set<String> tags) {
    if (tags.isEmpty) {
      _tags.remove(key);
    } else {
      _tags[key] = Set.unmodifiable(tags);
    }
  }

  void _touchLru(String key) {
    if (_maxEntries == null) return;
    _lru
      ..remove(key)
      ..add(key);
  }

  /// Evicts least-recently-used entries until the store fits [maxEntries].
  void _evictOverflow() {
    final max = _maxEntries;
    if (max == null) return;
    while (_lru.length > max) {
      final victim = _lru.first;
      _remove(victim);
      _evictions++;
      _logger.onEvict(victim);
    }
  }

  void _recordScope(String key, CacheScope scope) {
    if (scope == CacheScope.global) {
      _scopes.remove(key);
      return;
    }
    _scopes[key] = _ScopeMeta(
      scope,
      scope == CacheScope.user ? _activeUserId : null,
    );
  }

  List<String> _keysFor(bool Function(_ScopeMeta meta) predicate) {
    final out = <String>[];
    _scopes.forEach((key, meta) {
      if (predicate(meta)) out.add(key);
    });
    return out;
  }

  void _invalidateKeys(List<String> keys) {
    _evictions += keys.length;
    for (final key in keys) {
      invalidate(key);
    }
  }

  CacheScope _scopeFromName(String name) => CacheScope.values.firstWhere(
        (s) => s.name == name,
        orElse: () => CacheScope.global,
      );

  CacheCodec<dynamic>? _codecFor(String key) {
    CacheCodec<dynamic>? best;
    var bestLen = -1;
    _codecs.forEach((prefix, codec) {
      if (key.startsWith(prefix) && prefix.length > bestLen) {
        best = codec;
        bestLen = prefix.length;
      }
    });
    return best;
  }

  void _persist(String key, CacheEntry<dynamic> entry, CacheScope scope) {
    final store = _persistentStore;
    if (store == null) return;
    final codec = _codecFor(key);
    if (codec == null) return;

    final record = PersistedRecord(
      key: key,
      value: codec.encode(entry.value),
      createdAtMs: entry.createdAt.millisecondsSinceEpoch,
      ttlMs: entry.ttl?.inMilliseconds,
      scope: scope.name,
      userId: scope == CacheScope.user
          ? (_scopes[key]?.userId ?? _activeUserId)
          : null,
    );
    _track(store.save(record));
  }

  void _removeFromDisk(String key) {
    final store = _persistentStore;
    if (store == null) return;
    if (_codecFor(key) == null) return;
    _track(store.remove(key));
  }

  /// Tracks a fire-and-forget persistence op so [flush] can await it, and
  /// funnels any failure to [CacheLogger.onError] instead of going unhandled.
  void _track(Future<void> op) {
    late final Future<void> wrapped;
    wrapped = op
        .then(
          (_) {},
          onError: (Object e, StackTrace st) =>
              _logger.onError('<persistence>', e, st),
        )
        .whenComplete(() => _pendingPersistence.remove(wrapped));
    _pendingPersistence.add(wrapped);
  }

  Future<Result<T>> _runFetch<T>(
    String key,
    Fetcher<T> fetch, {
    required bool persist,
    required Duration? ttl,
    required RefreshSource source,
    required RetryOptions retryOptions,
    required bool cacheFailures,
    required CacheScope scope,
    required Set<String> tags,
  }) async {
    final existing = _inflight[key];
    if (existing != null) {
      final shared = await existing;
      return _castResult<T>(shared);
    }

    _refreshes++;
    _logger.onRefresh(key, source);
    final future = _fetchAndStore<T>(
      key,
      fetch,
      persist: persist,
      ttl: ttl,
      retryOptions: retryOptions,
      cacheFailures: cacheFailures,
      scope: scope,
      tags: tags,
    );
    _inflight[key] = future;
    try {
      return await future;
    } finally {
      if (identical(_inflight[key], future)) {
        _inflight.remove(key);
      }
    }
  }

  Future<Result<T>> _fetchAndStore<T>(
    String key,
    Fetcher<T> fetch, {
    required bool persist,
    required Duration? ttl,
    required RetryOptions retryOptions,
    required bool cacheFailures,
    required CacheScope scope,
    required Set<String> tags,
  }) async {
    Result<T> result = Failure<T>(StateError('unreachable'));
    var attempt = 0;

    while (true) {
      attempt++;
      try {
        result = await fetch();
      } catch (e, st) {
        result = Failure<T>(e, st);
      }

      if (result is Success<T>) break;

      final failure = result as Failure<T>;
      if (!retryOptions.shouldRetry(
        attempt,
        failure.error,
        failure.stackTrace,
      )) {
        break;
      }

      if (retryOptions.delay > Duration.zero) {
        await Future<void>.delayed(retryOptions.delay);
      }
    }

    if (result is Failure<T>) {
      _errors++;
      _logger.onError(key, result.error, result.stackTrace);
      if (persist && cacheFailures) {
        _failureCache[key] = _CachedFailure(
          failure: result,
          createdAt: _now(),
          ttl: ttl,
        );
        _recordScope(key, scope);
        _recordTags(key, tags);
      }
      return result;
    }

    if (persist && result is Success<T>) {
      _write<T>(key, result.value, ttl: ttl, scope: scope, tags: tags);
    }
    return result;
  }

  /// Stores [value], clears any cached failure, persists, and notifies
  /// watchers. Shared by [set], [update], and the fetch path.
  void _write<T>(
    String key,
    T value, {
    required Duration? ttl,
    required CacheScope scope,
    required Set<String> tags,
  }) {
    final entry = CacheEntry<T>(value: value, createdAt: _now(), ttl: ttl);
    _store.write(key, entry);
    _failureCache.remove(key);
    _recordScope(key, scope);
    _recordTags(key, tags);
    _writes++;
    _logger.onWrite(key, ttl: ttl);
    _persist(key, entry, scope);
    _touchLru(key);
    _evictOverflow();
    _emit<T>(key, Success<T>(value));
  }

  void _emit<T>(String key, Result<T> result) {
    final controller = _watchers[key];
    if (controller != null && !controller.isClosed) {
      controller.add(result);
    }
  }

  static Result<T> _castResult<T>(Result<dynamic> r) => switch (r) {
        Success() => Success<T>(r.value as T),
        Failure(:final error, :final stackTrace) =>
          Failure<T>(error, stackTrace),
      };
}
