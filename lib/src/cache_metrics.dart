/// An immutable snapshot of a cache's lifetime counters.
///
/// Read via `Cache.metrics`; reset via `Cache.resetMetrics()`. New in v1.2.0.
class CacheMetrics {
  const CacheMetrics({
    this.hits = 0,
    this.misses = 0,
    this.writes = 0,
    this.refreshes = 0,
    this.errors = 0,
    this.evictions = 0,
  });

  /// Reads served from a live (non-expired) cache entry.
  final int hits;

  /// Reads that found nothing fresh (absent or expired).
  final int misses;

  /// Successful values written into the store.
  final int writes;

  /// Fetcher invocations started (cache miss, policy fetch, refresh, etc.).
  final int refreshes;

  /// Fetcher outcomes that ended in a `Failure` (after exhausting retries).
  final int errors;

  /// Entries removed by lifecycle clears (`setActiveUser`, `endSession`,
  /// `clearScope`).
  final int evictions;

  /// Total lookups that hit the read path ([hits] + [misses]).
  int get lookups => hits + misses;

  /// Fraction of [lookups] served from cache, in `[0, 1]`. `0` when there
  /// have been no lookups yet.
  double get hitRate => lookups == 0 ? 0 : hits / lookups;

  CacheMetrics copyWith({
    int? hits,
    int? misses,
    int? writes,
    int? refreshes,
    int? errors,
    int? evictions,
  }) {
    return CacheMetrics(
      hits: hits ?? this.hits,
      misses: misses ?? this.misses,
      writes: writes ?? this.writes,
      refreshes: refreshes ?? this.refreshes,
      errors: errors ?? this.errors,
      evictions: evictions ?? this.evictions,
    );
  }

  @override
  String toString() =>
      'CacheMetrics(hits: $hits, misses: $misses, writes: $writes, '
      'refreshes: $refreshes, errors: $errors, evictions: $evictions, '
      'hitRate: ${(hitRate * 100).toStringAsFixed(1)}%)';
}
