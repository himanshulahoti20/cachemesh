import 'package:cachemesh/cachemesh.dart';
import 'package:test/test.dart';

class _EvictLogger extends CacheLogger {
  final evicted = <String>[];
  @override
  void onEvict(String key) => evicted.add(key);
}

void main() {
  group('maxEntries (LRU)', () {
    test('evicts the least recently used entry past capacity', () {
      final log = _EvictLogger();
      final cache = Cache(maxEntries: 2, logger: log);
      cache
        ..set<int>('a', 1)
        ..set<int>('b', 2);
      cache.peek<int>('a'); // a is now most recent
      cache.set<int>('c', 3); // evicts b
      expect(cache.allKeys.toSet(), {'a', 'c'});
      expect(log.evicted, ['b']);
      expect(cache.metrics.evictions, 1);
    });

    test('get hits refresh recency', () async {
      final cache = Cache(maxEntries: 2);
      cache
        ..set<int>('a', 1)
        ..set<int>('b', 2);
      await cache.get<int>(key: 'a', fetch: () async => const Success(0));
      cache.set<int>('c', 3);
      expect(cache.contains('a'), isTrue);
      expect(cache.contains('b'), isFalse);
    });

    test('invalidate frees a slot; overwrite does not grow the cache', () {
      final cache = Cache(maxEntries: 2);
      cache
        ..set<int>('a', 1)
        ..set<int>('b', 2)
        ..set<int>('a', 10);
      expect(cache.size, 2);
      cache.invalidate('b');
      cache.set<int>('c', 3);
      expect(cache.allKeys.toSet(), {'a', 'c'});
    });

    test('unbounded by default; rejects non-positive capacity', () {
      expect(Cache().maxEntries, isNull);
      expect(() => Cache(maxEntries: 0), throwsA(isA<AssertionError>()));
    });
  });

  group('tags', () {
    test('invalidateTag drops only tagged entries', () {
      final cache = Cache();
      cache
        ..set<int>('a', 1, tags: {'feed', 'home'})
        ..set<int>('b', 2, tags: {'feed'})
        ..set<int>('c', 3, tags: {'home'})
        ..set<int>('d', 4);
      expect(cache.invalidateTag('feed'), 2);
      expect(cache.allKeys.toSet(), {'c', 'd'});
      expect(cache.tagsOf('c'), {'home'});
      expect(cache.tagsOf('a'), isEmpty);
    });

    test('get tags the fetched entry', () async {
      final cache = Cache();
      await cache.get<int>(
        key: 'a',
        fetch: () async => const Success(1),
        tags: {'t'},
      );
      expect(cache.tagsOf('a'), {'t'});
      expect(cache.invalidateTag('t'), 1);
      expect(cache.contains('a'), isFalse);
    });

    test('update keeps tags; invalidateTag also drops cached failures',
        () async {
      final cache = Cache();
      cache.set<int>('a', 1, tags: {'t'});
      cache.update<int>('a', (v) => v + 1);
      expect(cache.tagsOf('a'), {'t'});
      await cache.get<int>(
        key: 'bad',
        fetch: () async => Failure<int>(StateError('x')),
        cacheFailures: true,
        tags: {'t'},
      );
      expect(cache.hasCachedFailure('bad'), isTrue);
      expect(cache.invalidateTag('t'), 2);
      expect(cache.hasCachedFailure('bad'), isFalse);
    });

    test('endpoint tags every entry it writes', () async {
      final cache = Cache();
      final ep = cache.endpoint<int, int>(
        key: (id) => 'n:$id',
        fetch: (id) async => Success(id),
        tags: {'nums'},
      );
      await ep(1);
      await ep(2);
      expect(cache.invalidateTag('nums'), 2);
    });
  });

  group('watch(emitCurrent)', () {
    test('emits the cached value first, then live updates', () async {
      final cache = Cache()..set<int>('n', 1);
      final events = <Result<int>>[];
      final sub = cache.watch<int>('n', emitCurrent: true).listen(events.add);
      cache.set<int>('n', 2);
      await Future<void>.delayed(Duration.zero);
      expect(events, [const Success<int>(1), const Success<int>(2)]);
      await sub.cancel();
    });

    test('absent key emits nothing extra; default stays live-only', () async {
      final cache = Cache();
      final withCurrent = <Result<int>>[];
      final plain = <Result<int>>[];
      cache.watch<int>('n', emitCurrent: true).listen(withCurrent.add);
      cache.set<int>('m', 0);
      cache.watch<int>('m').listen(plain.add);
      cache.set<int>('n', 1);
      cache.set<int>('m', 5);
      await Future<void>.delayed(Duration.zero);
      expect(withCurrent, [const Success<int>(1)]);
      expect(plain, [const Success<int>(5)]);
    });
  });
}
