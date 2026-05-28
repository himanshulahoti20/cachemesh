import 'dart:async';

import 'cache_codec.dart';
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
  })  : _store = store ?? MemoryCacheStore(),
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
      final scope = _scopeFromName(record.scope);
      if (scope != CacheScope.global) {
        _scopes[record.key] = _ScopeMeta(scope, record.userId);
      }
      restored++;
    }
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
    );
  }

  /// Drops the success and failure entries for [key] from memory and (if
  /// configured) the [PersistentStore].
  void invalidate(String key) {
    _store.delete(key);
    _failureCache.remove(key);
    _scopes.remove(key);
    _removeFromDisk(key);
    _logger.onInvalidate(key);
  }

  /// Drops every entry from the store, the failure cache, and (if configured)
  /// the [PersistentStore].
  void clear() {
    _store.clear();
    _failureCache.clear();
    _scopes.clear();
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
  Stream<Result<T>> watch<T>(String key) {
    final controller = _watchers.putIfAbsent(
      key,
      () => StreamController<Result<dynamic>>.broadcast(),
    );
    return controller.stream.map(_castResult<T>);
  }

  /// Synchronous, non-fetching read of the cache.
  ///
  /// Returns `null` if [key] is absent or (when [allowExpired] is `false`)
  /// expired. Use this to seed UI state from cache without triggering a fetch.
  T? peek<T>(String key, {bool allowExpired = false}) {
    final entry = _store.read(key);
    if (entry == null) return null;
    if (!allowExpired && entry.isExpiredAt(_now())) return null;
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
  /// New in v1.1.0.
  void clearScope(CacheScope scope) {
    final removed = _keysFor((meta) => meta.scope == scope);
    _invalidateKeys(removed);
    if (removed.isNotEmpty) {
      _logger.onScopeCleared('clearScope:${scope.name}', removed);
    }
  }

  /// Closes any open watcher streams. Safe to call multiple times.
  Future<void> dispose() async {
    final controllers = List.of(_watchers.values);
    _watchers.clear();
    for (final c in controllers) {
      await c.close();
    }
  }

  // ── internal helpers ───────────────────────────────────────────────────────

  void _hit(String key) {
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
    wrapped = op.then(
      (_) {},
      onError: (Object e, StackTrace st) =>
          _logger.onError('<persistence>', e, st),
    ).whenComplete(() => _pendingPersistence.remove(wrapped));
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
      }
      return result;
    }

    if (persist && result is Success<T>) {
      final entry =
          CacheEntry<T>(value: result.value, createdAt: _now(), ttl: ttl);
      _store.write(key, entry);
      _failureCache.remove(key);
      _recordScope(key, scope);
      _writes++;
      _logger.onWrite(key, ttl: ttl);
      _persist(key, entry, scope);
      _emit<T>(key, result);
    }
    return result;
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
