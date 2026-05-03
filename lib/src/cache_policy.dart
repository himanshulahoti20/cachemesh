/// Strategy that controls how `Cache.get` reconciles cache and fetch.
enum CachePolicy {
  /// Always fetch fresh data; fall back to a cached value if the fetch fails.
  networkFirst,

  /// Return a non-expired cached value if present; otherwise fetch and cache.
  cacheFirst,

  /// Return cached value (even if expired) immediately, then refresh in the
  /// background. Watchers receive the refreshed value when it arrives.
  ///
  /// This is the flagship policy for snappy UIs that still converge to fresh.
  staleWhileRevalidate,

  /// Always fetch; never read from or write to the cache.
  networkOnly,

  /// Read only from the cache. If the key is missing or expired, returns a
  /// [Failure] without invoking the fetcher.
  cacheOnly,
}
