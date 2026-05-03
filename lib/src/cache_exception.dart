/// Base type for failures originated by the cache itself (as opposed to
/// failures returned by a fetcher).
sealed class CacheException implements Exception {
  const CacheException(this.key);
  final String key;
}

/// Returned as a [Failure] when [CachePolicy.cacheOnly] is used and the key
/// is not present in the store.
final class CacheMissException extends CacheException {
  const CacheMissException(super.key);
  @override
  String toString() => 'CacheMissException: no entry for "$key"';
}

/// Returned as a [Failure] when [CachePolicy.cacheOnly] is used and the entry
/// exists but has already expired.
final class CacheExpiredException extends CacheException {
  const CacheExpiredException(super.key);
  @override
  String toString() => 'CacheExpiredException: entry for "$key" is expired';
}
