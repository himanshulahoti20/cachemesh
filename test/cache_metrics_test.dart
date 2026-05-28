import 'package:cachemesh/cachemesh.dart';
import 'package:test/test.dart';

void main() {
  late Cache cache;

  setUp(() => cache = Cache());
  tearDown(() async => cache.dispose());

  test('starts at zero', () {
    final m = cache.metrics;
    expect(m.hits, 0);
    expect(m.misses, 0);
    expect(m.writes, 0);
    expect(m.refreshes, 0);
    expect(m.errors, 0);
    expect(m.evictions, 0);
    expect(m.lookups, 0);
    expect(m.hitRate, 0);
  });

  test('tracks miss + refresh + write on first cacheFirst get', () async {
    await cache.get<int>(
      key: 'k',
      fetch: () async => const Success(1),
      policy: CachePolicy.cacheFirst,
    );
    final m = cache.metrics;
    expect(m.misses, 1);
    expect(m.refreshes, 1);
    expect(m.writes, 1);
    expect(m.hits, 0);
  });

  test('tracks hit on second cacheFirst get', () async {
    await cache.get<int>(
      key: 'k',
      fetch: () async => const Success(1),
      policy: CachePolicy.cacheFirst,
    );
    await cache.get<int>(
      key: 'k',
      fetch: () async => const Success(2),
      policy: CachePolicy.cacheFirst,
    );
    final m = cache.metrics;
    expect(m.hits, 1);
    expect(m.misses, 1);
    expect(m.lookups, 2);
    expect(m.hitRate, 0.5);
  });

  test('tracks errors', () async {
    await cache.get<int>(
      key: 'k',
      fetch: () async => Failure<int>('boom'),
      policy: CachePolicy.networkOnly,
    );
    expect(cache.metrics.errors, 1);
  });

  test('tracks evictions from lifecycle clears', () async {
    cache.setActiveUser('alice');
    await cache.refresh<int>(
      key: 'a',
      fetch: () async => const Success(1),
      scope: CacheScope.user,
    );
    await cache.refresh<int>(
      key: 'b',
      fetch: () async => const Success(2),
      scope: CacheScope.session,
    );
    cache.endSession();
    expect(cache.metrics.evictions, 2);
  });

  test('explicit invalidate does NOT count as eviction', () async {
    await cache.refresh<int>(key: 'k', fetch: () async => const Success(1));
    cache.invalidate('k');
    expect(cache.metrics.evictions, 0);
  });

  test('resetMetrics zeroes everything', () async {
    await cache.get<int>(
      key: 'k',
      fetch: () async => const Success(1),
      policy: CachePolicy.cacheFirst,
    );
    cache.resetMetrics();
    expect(cache.metrics.lookups, 0);
    expect(cache.metrics.writes, 0);
  });

  test('toString includes hitRate percentage', () async {
    await cache.get<int>(
      key: 'k',
      fetch: () async => const Success(1),
      policy: CachePolicy.cacheFirst,
    );
    await cache.get<int>(
      key: 'k',
      fetch: () async => const Success(1),
      policy: CachePolicy.cacheFirst,
    );
    expect(cache.metrics.toString(), contains('hitRate: 50.0%'));
  });
}
