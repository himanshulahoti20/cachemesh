/// The serializable, storage-facing form of a cache entry.
///
/// A [PersistentStore] deals exclusively in [PersistedRecord]s — the cache
/// converts between typed [CacheEntry] values and records using a registered
/// `CacheCodec`. New in v1.2.0.
class PersistedRecord {
  const PersistedRecord({
    required this.key,
    required this.value,
    required this.createdAtMs,
    this.ttlMs,
    this.scope = 'global',
    this.userId,
  });

  /// The cache key.
  final String key;

  /// JSON-encodable payload produced by a `CacheCodec.encode`.
  final Object? value;

  /// Creation time as epoch milliseconds.
  final int createdAtMs;

  /// TTL in milliseconds, or `null` for no expiration.
  final int? ttlMs;

  /// Scope name (`global` / `session` / `user`).
  final String scope;

  /// Owning user id for user-scoped records; `null` otherwise.
  final String? userId;

  Map<String, dynamic> toJson() => {
        'key': key,
        'value': value,
        'createdAtMs': createdAtMs,
        if (ttlMs != null) 'ttlMs': ttlMs,
        'scope': scope,
        if (userId != null) 'userId': userId,
      };

  factory PersistedRecord.fromJson(Map<String, dynamic> json) {
    return PersistedRecord(
      key: json['key'] as String,
      value: json['value'],
      createdAtMs: json['createdAtMs'] as int,
      ttlMs: json['ttlMs'] as int?,
      scope: (json['scope'] as String?) ?? 'global',
      userId: json['userId'] as String?,
    );
  }

  @override
  String toString() =>
      'PersistedRecord($key, scope: $scope, ttlMs: $ttlMs)';
}
