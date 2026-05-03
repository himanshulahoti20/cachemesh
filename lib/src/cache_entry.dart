/// A value stored in the cache together with the metadata needed to decide
/// whether it is still fresh.
class CacheEntry<T> {
  CacheEntry({
    required this.value,
    required this.createdAt,
    this.ttl,
  });

  /// The cached value.
  final T value;

  /// When this entry was written.
  final DateTime createdAt;

  /// How long this entry is considered fresh. `null` means no expiration.
  final Duration? ttl;

  /// The absolute moment at which this entry expires, or `null` if it never does.
  DateTime? get expiresAt => ttl == null ? null : createdAt.add(ttl!);

  /// `true` once [ttl] has elapsed. Entries without a ttl are never expired.
  bool isExpiredAt(DateTime now) {
    final exp = expiresAt;
    return exp != null && !now.isBefore(exp);
  }

  /// Convenience for [isExpiredAt] using `DateTime.now()`.
  bool get isExpired => isExpiredAt(DateTime.now());
}
