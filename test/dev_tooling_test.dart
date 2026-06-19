import 'package:cachemesh/cachemesh.dart';
import 'package:test/test.dart';

class _Clock {
  DateTime now = DateTime(2026, 1, 1);
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

void main() {
  group('size / allKeys / contains', () {
    test('reflect store membership', () async {
      final cache = Cache();
      expect(cache.size, 0);
      expect(cache.contains('k'), isFalse);

      await cache.refresh<int>(key: 'a', fetch: () async => const Success(1));
      await cache.refresh<int>(key: 'b', fetch: () async => const Success(2));

      expect(cache.size, 2);
      expect(cache.allKeys, containsAll(['a', 'b']));
      expect(cache.contains('a'), isTrue);
      await cache.dispose();
    });
  });

  group('snapshot', () {
    test('returns the state of every entry', () async {
      final cache = Cache();
      await cache.refresh<int>(
        key: 'a',
        fetch: () async => const Success(1),
        ttl: const Duration(minutes: 5),
      );
      final snap = cache.snapshot();
      expect(snap.keys, contains('a'));
      expect(snap['a']!.value, 1);
      expect(snap['a']!.isFresh, isTrue);
      await cache.dispose();
    });
  });

  group('touch', () {
    test('resets createdAt without re-fetching, keeping the same value',
        () async {
      final clock = _Clock();
      final cache = Cache(clock: clock.call);
      await cache.refresh<int>(
        key: 'a',
        fetch: () async => const Success(1),
        ttl: const Duration(seconds: 10),
      );

      clock.advance(const Duration(seconds: 8));
      cache.touch('a'); // resets createdAt to now (still has 10s)

      clock.advance(const Duration(seconds: 9));
      // Without touch this would be expired (createdAt+10s vs now=17s).
      // With touch, createdAt was moved to 8s, so expiry is at 18s.
      expect(cache.peek<int>('a'), 1);
      await cache.dispose();
    });

    test('can swap the TTL while touching', () async {
      final clock = _Clock();
      final cache = Cache(clock: clock.call);
      await cache.refresh<int>(
        key: 'a',
        fetch: () async => const Success(1),
        ttl: const Duration(seconds: 1),
      );
      cache.touch('a', ttl: const Duration(seconds: 60));
      clock.advance(const Duration(seconds: 30));
      expect(cache.peek<int>('a'), 1);
      await cache.dispose();
    });

    test('no-op on missing key', () {
      final cache = Cache();
      expect(() => cache.touch('nope'), returnsNormally);
    });
  });

  group('debugDump', () {
    test('renders a multi-line summary', () async {
      final cache = Cache();
      await cache.refresh<int>(
        key: 'a',
        fetch: () async => const Success(1),
        ttl: const Duration(minutes: 1),
      );
      final dump = cache.debugDump();
      expect(dump, contains('Cache(size=1'));
      expect(dump, contains('  - a'));
      expect(dump, contains('fresh'));
      await cache.dispose();
    });

    test('handles empty cache', () {
      final cache = Cache();
      expect(cache.debugDump(), contains('(no entries)'));
    });
  });

  group('clearScope(global) is a no-op', () {
    test('does not touch session entries', () async {
      final cache = Cache();
      await cache.refresh<int>(
        key: 's',
        fetch: () async => const Success(1),
        scope: CacheScope.session,
      );
      cache.clearScope(CacheScope.global);
      expect(cache.peek<int>('s'), 1);
      await cache.dispose();
    });
  });

  group('dispose flushes pending persistence', () {
    test('persistence writes outstanding at dispose still land on disk',
        () async {
      final disk = InMemoryPersistentStore();
      final cache = Cache(persistentStore: disk);
      cache.registerCodec<int>(
        'n:',
        CacheCodec<int>(encode: (v) => v, decode: (j) => j as int),
      );

      // Refresh schedules a write-through, then immediately dispose.
      await cache.refresh<int>(key: 'n:1', fetch: () async => const Success(7));
      await cache.dispose();

      expect(disk.length, 1);
    });
  });
}
