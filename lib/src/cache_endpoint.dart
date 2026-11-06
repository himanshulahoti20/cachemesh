import 'cache.dart';
import 'cache_policy.dart';
import 'cache_scope.dart';
import 'cache_state.dart';
import 'result.dart';
import 'retry_options.dart';
import 'token_keeper.dart';

/// Builds a stable cache key from typed parameters [P].
typedef KeyBuilder<P> = String Function(P params);

/// Fetcher used by a [CacheEndpoint] — receives the typed parameters [P].
typedef EndpointFetcher<P, T> = Future<Result<T>> Function(P params);

/// Fetcher used by an [AuthenticatedCacheEndpoint] — receives the typed
/// parameters [P] **and** a valid access token from the configured
/// [TokenKeeperAdapter].
typedef AuthEndpointFetcher<P, T> = Future<Result<T>> Function(
  P params,
  String token,
);

/// A reusable, parameterised view over the cache.
///
/// Bundle a key-builder, a fetcher, and a policy together once and reuse the
/// endpoint everywhere instead of repeating `cache.get(key: ..., fetch: ...)`
/// at every call site. This is the v2.0.0 unified-pipeline entry point.
///
/// ```dart
/// final users = cache.endpoint<int, User>(
///   key: (id) => 'user:$id',
///   fetch: (id) => api.fetchUser(id),
///   policy: CachePolicy.staleWhileRevalidate,
///   ttl: const Duration(minutes: 5),
/// );
///
/// await users(42);            // cached read
/// users.watch(42);            // reactive stream
/// await users.refresh(42);    // force refresh
/// users.invalidate(42);       // drop just this entry
/// users.invalidateAll();      // drop every entry produced by this endpoint
/// ```
class CacheEndpoint<P, T> {
  CacheEndpoint({
    required Cache cache,
    required this.key,
    required this.fetch,
    this.policy = CachePolicy.cacheFirst,
    this.ttl,
    this.scope = CacheScope.global,
    this.tags = const {},
    this.retryOptions,
    this.cacheFailures,
    this.alwaysRevalidate = false,
  }) : _cache = cache;

  final Cache _cache;

  /// Builds the cache key for a given set of parameters.
  final KeyBuilder<P> key;

  /// Default fetcher invoked by [call] / [refresh] / [prefetch].
  final EndpointFetcher<P, T> fetch;

  /// Default cache policy for [call].
  final CachePolicy policy;

  /// Default TTL applied to writes.
  final Duration? ttl;

  /// Default scope applied to writes.
  final CacheScope scope;

  /// Tags applied to every entry this endpoint writes (see
  /// [Cache.invalidateTag]). New in v2.1.0.
  final Set<String> tags;

  /// Default retry behaviour for fetches initiated by this endpoint.
  final RetryOptions? retryOptions;

  /// Whether to cache failures by default.
  final bool? cacheFailures;

  /// Default value for the SWR `alwaysRevalidate` flag.
  final bool alwaysRevalidate;

  /// Tracks the keys this endpoint has touched so [invalidateAll] only wipes
  /// its own entries instead of the whole cache.
  final Set<String> _ownedKeys = {};

  /// The set of keys this endpoint has produced. Useful in tests / debug.
  Iterable<String> get ownedKeys => _ownedKeys;

  /// Reads (and caches as needed) the value for [params].
  Future<Result<T>> call(P params) {
    final k = key(params);
    _ownedKeys.add(k);
    return _cache.get<T>(
      key: k,
      fetch: () => fetch(params),
      policy: policy,
      ttl: ttl,
      scope: scope,
      tags: tags,
      retryOptions: retryOptions,
      cacheFailures: cacheFailures,
      alwaysRevalidate: alwaysRevalidate,
    );
  }

  /// Forces a fresh fetch + write for [params].
  Future<Result<T>> refresh(P params) {
    final k = key(params);
    _ownedKeys.add(k);
    return _cache.refresh<T>(
      key: k,
      fetch: () => fetch(params),
      ttl: ttl,
      scope: scope,
      tags: tags,
      retryOptions: retryOptions,
      cacheFailures: cacheFailures,
    );
  }

  /// Warms the cache for [params] eagerly.
  Future<Result<T>> prefetch(P params) {
    final k = key(params);
    _ownedKeys.add(k);
    return _cache.prefetch<T>(
      key: k,
      fetch: () => fetch(params),
      ttl: ttl,
      scope: scope,
      tags: tags,
      retryOptions: retryOptions,
      cacheFailures: cacheFailures,
    );
  }

  /// Reactive stream of updates for [params].
  Stream<Result<T>> watch(P params) {
    final k = key(params);
    _ownedKeys.add(k);
    return _cache.watch<T>(k);
  }

  /// Synchronous, non-fetching read.
  T? peek(P params, {bool allowExpired = false}) =>
      _cache.peek<T>(key(params), allowExpired: allowExpired);

  /// Inspect the cache state for [params] without triggering a fetch.
  CacheState<T> inspect(P params) => _cache.inspect<T>(key(params));

  /// Drop the cache entry for [params].
  void invalidate(P params) {
    final k = key(params);
    _ownedKeys.remove(k);
    _cache.invalidate(k);
  }

  /// Drop every entry produced by this endpoint, leaving other cache entries
  /// untouched.
  void invalidateAll() {
    final keys = _ownedKeys.toList();
    _ownedKeys.clear();
    for (final k in keys) {
      _cache.invalidate(k);
    }
  }
}

/// Like [CacheEndpoint] but routes every fetch through the cache's configured
/// [TokenKeeperAdapter] so the fetcher receives a valid access token.
///
/// Defaults to [CacheScope.user] — authenticated data is per-user by default.
class AuthenticatedCacheEndpoint<P, T> {
  AuthenticatedCacheEndpoint({
    required Cache cache,
    required this.key,
    required this.fetch,
    this.policy = CachePolicy.cacheFirst,
    this.ttl,
    this.scope = CacheScope.user,
    this.tags = const {},
    this.retryOptions,
    this.cacheFailures,
    this.alwaysRevalidate = false,
  }) : _cache = cache;

  final Cache _cache;
  final KeyBuilder<P> key;
  final AuthEndpointFetcher<P, T> fetch;
  final CachePolicy policy;
  final Duration? ttl;
  final CacheScope scope;

  /// Tags applied to every entry this endpoint writes (see
  /// [Cache.invalidateTag]). New in v2.1.0.
  final Set<String> tags;
  final RetryOptions? retryOptions;
  final bool? cacheFailures;
  final bool alwaysRevalidate;
  final Set<String> _ownedKeys = {};

  Iterable<String> get ownedKeys => _ownedKeys;

  AuthenticatedAction<T> _bindAction(P params) =>
      (token) => fetch(params, token);

  Future<Result<T>> call(P params) {
    final k = key(params);
    _ownedKeys.add(k);
    return _cache.getAuthenticated<T>(
      key: k,
      fetch: _bindAction(params),
      policy: policy,
      ttl: ttl,
      scope: scope,
      tags: tags,
      retryOptions: retryOptions,
      cacheFailures: cacheFailures,
      alwaysRevalidate: alwaysRevalidate,
    );
  }

  /// Authenticated refresh — uses `getAuthenticated` via [CachePolicy.networkOnly]
  /// to force a network round-trip, then writes the result through the cache.
  Future<Result<T>> refresh(P params) {
    final k = key(params);
    _ownedKeys.add(k);
    return _cache.getAuthenticated<T>(
      key: k,
      fetch: _bindAction(params),
      // networkFirst forces the network round-trip and writes through the
      // cache on success, while still falling back to the cache when offline.
      policy: CachePolicy.networkFirst,
      ttl: ttl,
      scope: scope,
      tags: tags,
      retryOptions: retryOptions,
      cacheFailures: cacheFailures,
    );
  }

  Future<Result<T>> prefetch(P params) => call(params);

  Stream<Result<T>> watch(P params) {
    final k = key(params);
    _ownedKeys.add(k);
    return _cache.watch<T>(k);
  }

  T? peek(P params, {bool allowExpired = false}) =>
      _cache.peek<T>(key(params), allowExpired: allowExpired);

  CacheState<T> inspect(P params) => _cache.inspect<T>(key(params));

  void invalidate(P params) {
    final k = key(params);
    _ownedKeys.remove(k);
    _cache.invalidate(k);
  }

  void invalidateAll() {
    final keys = _ownedKeys.toList();
    _ownedKeys.clear();
    for (final k in keys) {
      _cache.invalidate(k);
    }
  }
}
