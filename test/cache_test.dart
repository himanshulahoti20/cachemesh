import 'dart:async';

import 'package:cachemesh/cachemesh.dart';
import 'package:test/test.dart';

class _Clock {
  DateTime now = DateTime(2026, 1, 1);
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

class _Counter {
  int calls = 0;
  Fetcher<int> success(int value) => () async {
        calls++;
        return Success<int>(value);
      };
  Fetcher<int> failure(Object err) => () async {
        calls++;
        return Failure<int>(err);
      };
  Fetcher<int> throwing(Object err) => () async {
        calls++;
        throw err;
      };
}

void main() {
  late _Clock clock;
  late Cache cache;
  late _Counter counter;

  setUp(() {
    clock = _Clock();
    cache = Cache(clock: clock.call);
    counter = _Counter();
  });

  tearDown(() async => cache.dispose());

  group('cacheFirst', () {
    test('miss => fetch, then subsequent calls hit cache', () async {
      final r1 = await cache.get<int>(
        key: 'k',
        fetch: counter.success(1),
        policy: CachePolicy.cacheFirst,
      );
      final r2 = await cache.get<int>(
        key: 'k',
        fetch: counter.success(2),
        policy: CachePolicy.cacheFirst,
      );
      expect(r1, const Success<int>(1));
      expect(r2, const Success<int>(1));
      expect(counter.calls, 1);
    });

    test('expired entry triggers refetch', () async {
      await cache.get<int>(
        key: 'k',
        fetch: counter.success(1),
        policy: CachePolicy.cacheFirst,
        ttl: const Duration(minutes: 5),
      );
      clock.advance(const Duration(minutes: 6));
      final r = await cache.get<int>(
        key: 'k',
        fetch: counter.success(2),
        policy: CachePolicy.cacheFirst,
        ttl: const Duration(minutes: 5),
      );
      expect(r, const Success<int>(2));
      expect(counter.calls, 2);
    });
  });

  group('networkFirst', () {
    test('success caches the result', () async {
      final r = await cache.get<int>(
        key: 'k',
        fetch: counter.success(7),
        policy: CachePolicy.networkFirst,
      );
      expect(r, const Success<int>(7));
      expect(cache.peek<int>('k'), 7);
    });

    test('failure falls back to cached value', () async {
      await cache.get<int>(
        key: 'k',
        fetch: counter.success(7),
        policy: CachePolicy.networkFirst,
      );
      final r = await cache.get<int>(
        key: 'k',
        fetch: counter.failure('offline'),
        policy: CachePolicy.networkFirst,
      );
      expect(r, const Success<int>(7));
    });

    test('failure with no cache returns the failure', () async {
      final r = await cache.get<int>(
        key: 'k',
        fetch: counter.failure('offline'),
        policy: CachePolicy.networkFirst,
      );
      expect(r.isFailure, isTrue);
      expect(r.errorOrNull, 'offline');
    });
  });

  group('networkOnly', () {
    test('always fetches and never writes to cache', () async {
      await cache.get<int>(
        key: 'k',
        fetch: counter.success(1),
        policy: CachePolicy.networkOnly,
      );
      await cache.get<int>(
        key: 'k',
        fetch: counter.success(2),
        policy: CachePolicy.networkOnly,
      );
      expect(counter.calls, 2);
      expect(cache.peek<int>('k'), isNull);
    });
  });

  group('cacheOnly', () {
    test('miss => failure with CacheMissException, no fetch', () async {
      final r = await cache.get<int>(
        key: 'k',
        fetch: counter.success(1),
        policy: CachePolicy.cacheOnly,
      );
      expect(r.isFailure, isTrue);
      expect(r.errorOrNull, isA<CacheMissException>());
      expect(counter.calls, 0);
    });

    test('expired => failure with CacheExpiredException', () async {
      await cache.get<int>(
        key: 'k',
        fetch: counter.success(1),
        policy: CachePolicy.cacheFirst,
        ttl: const Duration(seconds: 10),
      );
      clock.advance(const Duration(seconds: 11));
      final r = await cache.get<int>(
        key: 'k',
        fetch: counter.success(2),
        policy: CachePolicy.cacheOnly,
      );
      expect(r.isFailure, isTrue);
      expect(r.errorOrNull, isA<CacheExpiredException>());
    });

    test('hit returns cached value', () async {
      await cache.get<int>(
        key: 'k',
        fetch: counter.success(99),
        policy: CachePolicy.cacheFirst,
      );
      final r = await cache.get<int>(
        key: 'k',
        fetch: counter.success(0),
        policy: CachePolicy.cacheOnly,
      );
      expect(r, const Success<int>(99));
    });
  });

  group('staleWhileRevalidate', () {
    test(
      'returns cached immediately and refreshes in the background',
      () async {
        await cache.get<int>(
          key: 'k',
          fetch: counter.success(1),
          policy: CachePolicy.cacheFirst,
        );
        // Now there's a cached value of 1 with 1 fetch consumed.
        // alwaysRevalidate: true exercises the "refresh even when fresh" path.
        final r = await cache.get<int>(
          key: 'k',
          fetch: counter.success(2),
          policy: CachePolicy.staleWhileRevalidate,
          alwaysRevalidate: true,
        );
        expect(r, const Success<int>(1));

        // Let the background refresh complete.
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(counter.calls, 2);
        expect(cache.peek<int>('k'), 2);
      },
    );

    test(
      'no cached value => fetches and returns synchronously-awaited result',
      () async {
        final r = await cache.get<int>(
          key: 'k',
          fetch: counter.success(5),
          policy: CachePolicy.staleWhileRevalidate,
        );
        expect(r, const Success<int>(5));
        expect(counter.calls, 1);
      },
    );

    test('serves stale (expired) value immediately', () async {
      await cache.get<int>(
        key: 'k',
        fetch: counter.success(1),
        policy: CachePolicy.cacheFirst,
        ttl: const Duration(seconds: 5),
      );
      clock.advance(const Duration(seconds: 10));

      final r = await cache.get<int>(
        key: 'k',
        fetch: counter.success(2),
        policy: CachePolicy.staleWhileRevalidate,
      );
      expect(r, const Success<int>(1));
      await Future<void>.delayed(Duration.zero);
      expect(cache.peek<int>('k'), 2);
    });
  });

  group('single-flight', () {
    test('concurrent gets share a single fetch', () async {
      final completer = Completer<Result<int>>();
      Fetcher<int> slow() => () {
            counter.calls++;
            return completer.future;
          };

      final futures = List.generate(
        5,
        (_) => cache.get<int>(
          key: 'k',
          fetch: slow(),
          policy: CachePolicy.networkFirst,
        ),
      );
      // Give the first fetch a chance to register in _inflight.
      await Future<void>.delayed(Duration.zero);
      completer.complete(const Success<int>(42));

      final results = await Future.wait(futures);
      expect(results, everyElement(const Success<int>(42)));
      expect(counter.calls, 1);
    });
  });

  group('watch', () {
    test('emits when get persists a fresh value', () async {
      final events = <Result<int>>[];
      final sub = cache.watch<int>('k').listen(events.add);

      await cache.get<int>(
        key: 'k',
        fetch: counter.success(1),
        policy: CachePolicy.cacheFirst,
      );
      await Future<void>.delayed(Duration.zero);

      expect(events, [const Success<int>(1)]);
      await sub.cancel();
    });

    test('emits the SWR background refresh', () async {
      await cache.get<int>(
        key: 'k',
        fetch: counter.success(1),
        policy: CachePolicy.cacheFirst,
      );

      final events = <Result<int>>[];
      final sub = cache.watch<int>('k').listen(events.add);

      await cache.get<int>(
        key: 'k',
        fetch: counter.success(2),
        policy: CachePolicy.staleWhileRevalidate,
        alwaysRevalidate: true,
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(events, [const Success<int>(2)]);
      await sub.cancel();
    });

    test('does not emit for networkOnly', () async {
      final events = <Result<int>>[];
      final sub = cache.watch<int>('k').listen(events.add);

      await cache.get<int>(
        key: 'k',
        fetch: counter.success(1),
        policy: CachePolicy.networkOnly,
      );
      await Future<void>.delayed(Duration.zero);

      expect(events, isEmpty);
      await sub.cancel();
    });
  });

  group('failures are not cached by default', () {
    test('failed fetch leaves the cache empty', () async {
      final r = await cache.get<int>(
        key: 'k',
        fetch: counter.failure('boom'),
        policy: CachePolicy.cacheFirst,
      );
      expect(r.isFailure, isTrue);
      expect(cache.peek<int>('k'), isNull);
    });

    test('thrown exceptions are converted to Failure', () async {
      final r = await cache.get<int>(
        key: 'k',
        fetch: counter.throwing(StateError('nope')),
        policy: CachePolicy.networkOnly,
      );
      expect(r.isFailure, isTrue);
      expect(r.errorOrNull, isA<StateError>());
    });
  });

  group('manual control', () {
    test('refresh forces a fetch and updates cache', () async {
      await cache.get<int>(
        key: 'k',
        fetch: counter.success(1),
        policy: CachePolicy.cacheFirst,
      );
      final r = await cache.refresh<int>(key: 'k', fetch: counter.success(2));
      expect(r, const Success<int>(2));
      expect(cache.peek<int>('k'), 2);
      expect(counter.calls, 2);
    });

    test('invalidate drops the entry', () async {
      await cache.get<int>(
        key: 'k',
        fetch: counter.success(1),
        policy: CachePolicy.cacheFirst,
      );
      cache.invalidate('k');
      expect(cache.peek<int>('k'), isNull);
    });

    test('clear empties the entire cache', () async {
      await cache.get<int>(
        key: 'a',
        fetch: counter.success(1),
        policy: CachePolicy.cacheFirst,
      );
      await cache.get<int>(
        key: 'b',
        fetch: counter.success(2),
        policy: CachePolicy.cacheFirst,
      );
      cache.clear();
      expect(cache.peek<int>('a'), isNull);
      expect(cache.peek<int>('b'), isNull);
    });

    test('prefetch warms the cache so the next get is a hit', () async {
      await cache.prefetch<int>(key: 'k', fetch: counter.success(7));
      final r = await cache.get<int>(
        key: 'k',
        fetch: counter.success(99),
        policy: CachePolicy.cacheFirst,
      );
      expect(r, const Success<int>(7));
      expect(counter.calls, 1);
    });
  });

  group('peek', () {
    test('respects expiration by default', () async {
      await cache.get<int>(
        key: 'k',
        fetch: counter.success(1),
        policy: CachePolicy.cacheFirst,
        ttl: const Duration(seconds: 5),
      );
      clock.advance(const Duration(seconds: 10));
      expect(cache.peek<int>('k'), isNull);
      expect(cache.peek<int>('k', allowExpired: true), 1);
    });
  });
}
