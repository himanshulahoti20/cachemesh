/// Why a fetch was triggered. Useful for filtering noise in logs and metrics.
enum RefreshSource {
  /// `cacheFirst` looked up the key but found nothing fresh.
  cacheMiss,

  /// An always-fetch policy (`networkFirst`, `networkOnly`) ran.
  policy,

  /// `staleWhileRevalidate` returned stale data and kicked off a refresh in
  /// the background.
  background,

  /// User-invoked `Cache.refresh`.
  refresh,

  /// User-invoked `Cache.prefetch`.
  prefetch,
}

/// Pluggable logger for cache lifecycle events.
///
/// All methods have no-op defaults — override only the events you care about.
/// Pass an instance to `Cache(logger: ...)` to receive callbacks.
///
/// New in v1.0.1.
class CacheLogger {
  const CacheLogger();

  /// A non-expired entry was returned from the store without a fetch.
  void onHit(String key) {}

  /// The store was queried and either had no entry or had an expired one.
  /// Fired before any subsequent fetch.
  void onMiss(String key) {}

  /// A new value was just written to the store under [key].
  void onWrite(String key, {Duration? ttl}) {}

  /// A fetcher is about to run for [key], driven by [source].
  void onRefresh(String key, RefreshSource source) {}

  /// [Cache.invalidate] removed an entry.
  void onInvalidate(String key) {}

  /// [Cache.clear] dropped every entry.
  void onClear() {}

  /// A fetcher returned a `Failure` or threw.
  void onError(String key, Object error, StackTrace? stackTrace) {}
}

/// Convenience [CacheLogger] that prints every event to stdout.
///
/// Tag every line with [tag] to disambiguate when multiple caches are in use.
class PrintCacheLogger extends CacheLogger {
  const PrintCacheLogger({this.tag = 'cachemesh'});

  final String tag;

  void _log(String message) {
    // ignore: avoid_print
    print('[$tag] $message');
  }

  @override
  void onHit(String key) => _log('hit  $key');

  @override
  void onMiss(String key) => _log('miss $key');

  @override
  void onWrite(String key, {Duration? ttl}) =>
      _log('write $key${ttl == null ? '' : ' ttl=${ttl.inMilliseconds}ms'}');

  @override
  void onRefresh(String key, RefreshSource source) =>
      _log('refresh $key (${source.name})');

  @override
  void onInvalidate(String key) => _log('invalidate $key');

  @override
  void onClear() => _log('clear');

  @override
  void onError(String key, Object error, StackTrace? stackTrace) =>
      _log('error $key: $error');
}
