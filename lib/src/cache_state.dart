/// A read-only snapshot of what the cache currently knows about a key.
///
/// Returned by `Cache.inspect`. Use it to drive UI state (skeleton vs stale
/// banner vs fresh) without triggering a fetch. New in v1.0.1.
class CacheState<T> {
  const CacheState({
    required this.key,
    required this.now,
    this.value,
    this.createdAt,
    this.ttl,
  });

  /// The key being inspected.
  final String key;

  /// The clock reading at which this snapshot was taken.
  final DateTime now;

  /// The cached value, or `null` if [isMissing].
  final T? value;

  /// When the cached entry was written, or `null` if [isMissing].
  final DateTime? createdAt;

  /// The TTL configured at write time, or `null` for no expiration.
  final Duration? ttl;

  /// `true` if the cache holds an entry for [key] (regardless of freshness).
  bool get isPresent => createdAt != null;

  /// `true` if the cache has no entry for [key].
  bool get isMissing => !isPresent;

  /// Absolute moment at which this entry expires, or `null` if it never does.
  DateTime? get expiresAt {
    if (createdAt == null || ttl == null) return null;
    return createdAt!.add(ttl!);
  }

  /// How long ago this entry was written, or `null` if [isMissing].
  Duration? get age {
    if (createdAt == null) return null;
    return now.difference(createdAt!);
  }

  /// Time until expiration, or `null` if [isMissing] or no [ttl] is set.
  /// Negative values mean the entry is already past its TTL.
  Duration? get timeToExpiry {
    final exp = expiresAt;
    if (exp == null) return null;
    return exp.difference(now);
  }

  /// `true` when an entry exists and is still within its TTL (or has no TTL).
  bool get isFresh {
    if (!isPresent) return false;
    final exp = expiresAt;
    if (exp == null) return true;
    return now.isBefore(exp);
  }

  /// `true` when an entry exists but is past its TTL.
  bool get isStale => isPresent && !isFresh;

  @override
  String toString() {
    if (isMissing) return 'CacheState($key: missing)';
    final freshness = isFresh ? 'fresh' : 'stale';
    final ttlPart = ttl == null ? 'no-ttl' : 'ttl=${ttl!.inMilliseconds}ms';
    return 'CacheState($key: $freshness, age=${age!.inMilliseconds}ms, $ttlPart)';
  }
}
