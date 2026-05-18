import 'dart:async';

import 'cache_entry.dart';
import 'cache_exception.dart';
import 'cache_logger.dart';
import 'cache_policy.dart';
import 'cache_scope.dart';
import 'cache_state.dart';
import 'cache_store.dart';
import 'memory_cache_store.dart';
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
/// (single-flight), broadcasts updates to [watch] subscribers, and (v1.1.0)
/// understands lifecycle scopes so personal data doesn't leak across sessions.
class Cache {
  Cache({
    CacheStore? store,
    Duration? defaultTtl,
    DateTime Function()? clock,
    CacheLogger? logger,
    RetryOptions? retryOptions,
    bool cacheFailures = false,
    TokenKeeperAdapter? tokenKeeper,
  })  : _store = store ?? MemoryCacheStore(),
        _defaultTtl = defaultTtl,
        _now = clock ?? DateTime.now,
        _logger = logger ?? const CacheLogger(),
        _defaultRetryOptions = retryOptions ?? RetryOptions.noRetry,
        _defaultCacheFailures = cacheFailures,
        _tokenKeeper = tokenKeeper;

  final CacheStore _store;
  final Duration? _defaultTtl;
  final DateTime Function() _now;
  final CacheLogger _logger;
  final RetryOptions _defaultRetryOptions;
  final bool _defaultCacheFailures;
  final TokenKeeperAdapter? _tokenKeeper;

  final Map<String, Future<Result<dynamic>>> _inflight = {};
  final Map<String, StreamController<Result<dynamic>>> _watchers = {};

  // v1.0.2 — separate store for cached failures.
  final Map<String, _CachedFailure> _failureCache = {};

  // v1.1.0 — scope metadata per key. Absent => global.
  final Map<String, _ScopeMeta> _scopes = {};
  String? _activeUserId;

  /// The currently active user id, or `null` if no user is signed in.
  /// Set via [setActiveUser]. Affects [CacheScope.user] entries.
  String? get activeUserId => _activeUserId;

  /// The token keeper passed at construction, or `null` if none was provided.
  /// Used by [getAuthenticated].
  TokenKeeperAdapter? get tokenKeeper => _tokenKeeper;

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
          _logger.onMiss(key);
          return entry == null
              ? Failure<T>(CacheMissException(key))
              : Failure<T>(CacheExpiredException(key));
        }
        _logger.onHit(key);
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
          _logger.onHit(key);
          return Success<T>(entry.value as T);
        }
        final cached = _failureCache[key];
        if (cached != null && !cached.isExpiredAt(now)) {
          return _castResult<T>(cached.failure);
        }
        _logger.onMiss(key);
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
          _logger.onHit(key);
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
          _logger.onHit(key);
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
        _logger.onMiss(key);
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

  /// Drops the success and failure entries for [key].
  void invalidate(String key) {
    _store.delete(key);
    _failureCache.remove(key);
    _scopes.remove(key);
    _logger.onInvalidate(key);
  }

  /// Drops every entry from the store and the failure cache.
  void clear() {
    _store.clear();
    _failureCache.clear();
    _scopes.clear();
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

  /// Changes the active user id and clears entries tied to the previous user.
  ///
  /// Passing `null` is equivalent to a logout for user-scoped data — see
  /// [endSession] when you also want to drop [CacheScope.session] entries.
  ///
  /// No-op when [userId] equals [activeUserId].
  ///
  /// New in v1.1.0.
  void setActiveUser(String? userId) {
    if (userId == _activeUserId) return;
    final previous = _activeUserId;
    _activeUserId = userId;

    final removed = _keysFor(
      (meta) => meta.scope == CacheScope.user && meta.userId == previous,
    );
    _invalidateKeys(removed);
    if (removed.isNotEmpty) {
      _logger.onScopeCleared('setActiveUser', removed);
    }
  }

  /// Drops [CacheScope.session] entries and user-scoped entries for the
  /// previously-active user, and clears [activeUserId].
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
  /// `clearScope(CacheScope.global)` is a no-op alias for [clear] except that
  /// it leaves user/session entries in place — pass [clear] if you want
  /// everything gone.
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
    for (final key in keys) {
      invalidate(key);
    }
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
    int attempt = 0;

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
      _store.write(
        key,
        CacheEntry<T>(value: result.value, createdAt: _now(), ttl: ttl),
      );
      _failureCache.remove(key);
      _recordScope(key, scope);
      _logger.onWrite(key, ttl: ttl);
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
