import 'package:cachemesh/cachemesh.dart';
import 'package:test/test.dart';

class _Clock {
  DateTime now = DateTime(2026, 1, 1);
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

void main() {
  late _Clock clock;
  late Cache cache;

  setUp(() {
    clock = _Clock();
    cache = Cache(clock: clock.call);
  });

  tearDown(() async => cache.dispose());

  group('failure caching disabled (default)', () {
    test('failures are not stored; next cacheFirst get retries', () async {
      int calls = 0;
      await cache.get<int>(
        key: 'k',
        fetch: () async {
          calls++;
          return Failure<int>('net');
        },
        policy: CachePolicy.cacheFirst,
      );
      await cache.get<int>(
        key: 'k',
        fetch: () async {
          calls++;
          return Failure<int>('net');
        },
        policy: CachePolicy.cacheFirst,
      );
      expect(calls, 2);
      expect(cache.hasCachedFailure('k'), isFalse);
    });
  });

  group('cacheFailures: true', () {
    test('failure is stored; subsequent cacheFirst get returns cached failure',
        () async {
      int calls = 0;
      final r1 = await cache.get<int>(
        key: 'k',
        fetch: () async {
          calls++;
          return Failure<int>('rate-limited');
        },
        policy: CachePolicy.cacheFirst,
        cacheFailures: true,
        ttl: const Duration(minutes: 1),
      );
      final r2 = await cache.get<int>(
        key: 'k',
        fetch: () async {
          calls++;
          return Failure<int>('should not reach');
        },
        policy: CachePolicy.cacheFirst,
        cacheFailures: true,
      );
      expect(r1.isFailure, isTrue);
      expect(r2.isFailure, isTrue);
      expect((r2 as Failure<int>).error, 'rate-limited');
      expect(calls, 1);
      expect(cache.hasCachedFailure('k'), isTrue);
    });

    test('cached failure respects TTL; re-fetches after expiry', () async {
      int calls = 0;
      await cache.get<int>(
        key: 'k',
        fetch: () async {
          calls++;
          return Failure<int>('x');
        },
        policy: CachePolicy.cacheFirst,
        cacheFailures: true,
        ttl: const Duration(seconds: 5),
      );
      clock.advance(const Duration(seconds: 6));
      expect(cache.hasCachedFailure('k'), isFalse);
      await cache.get<int>(
        key: 'k',
        fetch: () async {
          calls++;
          return Failure<int>('x');
        },
        policy: CachePolicy.cacheFirst,
        cacheFailures: true,
        ttl: const Duration(seconds: 5),
      );
      expect(calls, 2);
    });

    test('successful re-fetch clears the cached failure', () async {
      await cache.get<int>(
        key: 'k',
        fetch: () async => Failure<int>('x'),
        policy: CachePolicy.cacheFirst,
        cacheFailures: true,
      );
      expect(cache.hasCachedFailure('k'), isTrue);

      await cache.refresh<int>(
        key: 'k',
        fetch: () async => const Success<int>(1),
      );
      expect(cache.hasCachedFailure('k'), isFalse);
      expect(cache.peek<int>('k'), 1);
    });

    test('invalidate removes both success and failure entries', () async {
      await cache.get<int>(
        key: 'k',
        fetch: () async => Failure<int>('x'),
        policy: CachePolicy.cacheFirst,
        cacheFailures: true,
      );
      cache.invalidate('k');
      expect(cache.hasCachedFailure('k'), isFalse);
    });

    test('clear removes all failure entries', () async {
      await cache.get<int>(
        key: 'a',
        fetch: () async => Failure<int>('x'),
        policy: CachePolicy.cacheFirst,
        cacheFailures: true,
      );
      await cache.get<int>(
        key: 'b',
        fetch: () async => Failure<int>('y'),
        policy: CachePolicy.cacheFirst,
        cacheFailures: true,
      );
      cache.clear();
      expect(cache.hasCachedFailure('a'), isFalse);
      expect(cache.hasCachedFailure('b'), isFalse);
    });

    test('cacheOnly returns cached failure without fetching', () async {
      int calls = 0;
      await cache.get<int>(
        key: 'k',
        fetch: () async {
          calls++;
          return Failure<int>('x');
        },
        policy: CachePolicy.cacheFirst,
        cacheFailures: true,
      );
      final r = await cache.get<int>(
        key: 'k',
        fetch: () async {
          calls++;
          return const Success<int>(99);
        },
        policy: CachePolicy.cacheOnly,
      );
      expect(r.isFailure, isTrue);
      expect(calls, 1);
    });
  });

  group('Cache-level cacheFailures default', () {
    setUp(() {
      cache = Cache(clock: clock.call, cacheFailures: true);
    });

    test('failures are cached by default', () async {
      int calls = 0;
      await cache.get<int>(
        key: 'k',
        fetch: () async {
          calls++;
          return Failure<int>('x');
        },
        policy: CachePolicy.cacheFirst,
      );
      await cache.get<int>(
        key: 'k',
        fetch: () async {
          calls++;
          return Failure<int>('x');
        },
        policy: CachePolicy.cacheFirst,
      );
      expect(calls, 1);
    });

    test('per-call cacheFailures: false overrides the default', () async {
      int calls = 0;
      await cache.get<int>(
        key: 'k',
        fetch: () async {
          calls++;
          return Failure<int>('x');
        },
        policy: CachePolicy.cacheFirst,
        cacheFailures: false,
      );
      await cache.get<int>(
        key: 'k',
        fetch: () async {
          calls++;
          return Failure<int>('x');
        },
        policy: CachePolicy.cacheFirst,
        cacheFailures: false,
      );
      expect(calls, 2);
    });
  });

  group('SWR: smarter stale-only revalidation (v1.0.2)', () {
    test('fresh entry does NOT trigger background refresh by default',
        () async {
      int calls = 0;
      await cache.get<int>(
        key: 'k',
        fetch: () async {
          calls++;
          return const Success<int>(1);
        },
        policy: CachePolicy.cacheFirst,
        ttl: const Duration(minutes: 5),
      );
      // Entry is still fresh — SWR should not refresh.
      await cache.get<int>(
        key: 'k',
        fetch: () async {
          calls++;
          return const Success<int>(2);
        },
        policy: CachePolicy.staleWhileRevalidate,
        ttl: const Duration(minutes: 5),
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      expect(cache.peek<int>('k'), 1);
    });

    test('stale entry triggers background refresh', () async {
      int calls = 0;
      await cache.get<int>(
        key: 'k',
        fetch: () async {
          calls++;
          return const Success<int>(1);
        },
        policy: CachePolicy.cacheFirst,
        ttl: const Duration(seconds: 5),
      );
      clock.advance(const Duration(seconds: 6));

      await cache.get<int>(
        key: 'k',
        fetch: () async {
          calls++;
          return const Success<int>(2);
        },
        policy: CachePolicy.staleWhileRevalidate,
        ttl: const Duration(seconds: 5),
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls, 2);
      expect(cache.peek<int>('k'), 2);
    });

    test('alwaysRevalidate: true restores old always-refresh behaviour',
        () async {
      int calls = 0;
      await cache.get<int>(
        key: 'k',
        fetch: () async {
          calls++;
          return const Success<int>(1);
        },
        policy: CachePolicy.cacheFirst,
        ttl: const Duration(minutes: 5),
      );
      // Entry is fresh, but caller requests always-revalidate.
      await cache.get<int>(
        key: 'k',
        fetch: () async {
          calls++;
          return const Success<int>(2);
        },
        policy: CachePolicy.staleWhileRevalidate,
        ttl: const Duration(minutes: 5),
        alwaysRevalidate: true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls, 2);
      expect(cache.peek<int>('k'), 2);
    });
  });
}
