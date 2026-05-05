import 'package:cachemesh/cachemesh.dart';
import 'package:test/test.dart';

void main() {
  late Cache cache;

  tearDown(() async => cache.dispose());

  group('RetryOptions.noRetry (default)', () {
    setUp(() => cache = Cache());

    test('single attempt, failure propagates immediately', () async {
      int calls = 0;
      final r = await cache.get<int>(
        key: 'k',
        fetch: () async {
          calls++;
          return Failure<int>('boom');
        },
        policy: CachePolicy.networkOnly,
      );
      expect(r.isFailure, isTrue);
      expect(calls, 1);
    });
  });

  group('RetryOptions: maxAttempts', () {
    setUp(() => cache = Cache());

    test('retries up to maxAttempts then returns final failure', () async {
      int calls = 0;
      final r = await cache.get<int>(
        key: 'k',
        fetch: () async {
          calls++;
          return Failure<int>('net');
        },
        policy: CachePolicy.networkOnly,
        retryOptions: const RetryOptions(maxAttempts: 3),
      );
      expect(r.isFailure, isTrue);
      expect(calls, 3);
    });

    test('stops retrying after a success', () async {
      int calls = 0;
      final r = await cache.get<int>(
        key: 'k',
        fetch: () async {
          calls++;
          if (calls < 3) return Failure<int>('net');
          return const Success<int>(42);
        },
        policy: CachePolicy.networkOnly,
        retryOptions: const RetryOptions(maxAttempts: 5),
      );
      expect(r, const Success<int>(42));
      expect(calls, 3);
    });
  });

  group('RetryOptions: retryWhen predicate', () {
    setUp(() => cache = Cache());

    test('does not retry when predicate returns false', () async {
      int calls = 0;
      final r = await cache.get<int>(
        key: 'k',
        fetch: () async {
          calls++;
          return Failure<int>(StateError('unauthorized'));
        },
        policy: CachePolicy.networkOnly,
        retryOptions: RetryOptions(
          maxAttempts: 5,
          retryWhen: (e, _) => e is! StateError,
        ),
      );
      expect(r.isFailure, isTrue);
      expect(calls, 1);
    });

    test('retries when predicate returns true, stops on false', () async {
      int calls = 0;
      final errors = <Object>[];
      final r = await cache.get<int>(
        key: 'k',
        fetch: () async {
          calls++;
          if (calls < 3) return Failure<int>('network');
          return Failure<int>(StateError('unauthorized'));
        },
        policy: CachePolicy.networkOnly,
        retryOptions: RetryOptions(
          maxAttempts: 10,
          retryWhen: (e, _) {
            errors.add(e);
            return e is! StateError;
          },
        ),
      );
      expect(r.isFailure, isTrue);
      expect(calls, 3);
      // predicate was called for 'network' x2 and then for the StateError
      expect(errors.last, isA<StateError>());
    });
  });

  group('RetryOptions: delay', () {
    setUp(() => cache = Cache());

    test('adds delay between attempts', () async {
      int calls = 0;
      final stopwatch = Stopwatch()..start();
      await cache.get<int>(
        key: 'k',
        fetch: () async {
          calls++;
          return Failure<int>('x');
        },
        policy: CachePolicy.networkOnly,
        retryOptions: const RetryOptions(
          maxAttempts: 3,
          delay: Duration(milliseconds: 20),
        ),
      );
      stopwatch.stop();
      expect(calls, 3);
      // 2 delays of 20ms each = at least 40ms
      expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(35));
    });
  });

  group('RetryOptions: Cache-level default', () {
    setUp(() {
      cache = Cache(retryOptions: const RetryOptions(maxAttempts: 3));
    });

    test('cache-level default applies to all gets', () async {
      int calls = 0;
      await cache.get<int>(
        key: 'k',
        fetch: () async {
          calls++;
          return Failure<int>('x');
        },
        policy: CachePolicy.networkOnly,
      );
      expect(calls, 3);
    });

    test('per-call retryOptions overrides cache default', () async {
      int calls = 0;
      await cache.get<int>(
        key: 'k',
        fetch: () async {
          calls++;
          return Failure<int>('x');
        },
        policy: CachePolicy.networkOnly,
        retryOptions: RetryOptions.noRetry,
      );
      expect(calls, 1);
    });
  });

  group('thrown exceptions are retried like returned Failures', () {
    setUp(() => cache = Cache());

    test('exception in fetcher counts as one attempt', () async {
      int calls = 0;
      final r = await cache.get<int>(
        key: 'k',
        fetch: () async {
          calls++;
          throw Exception('crash');
        },
        policy: CachePolicy.networkOnly,
        retryOptions: const RetryOptions(maxAttempts: 4),
      );
      expect(r.isFailure, isTrue);
      expect(r.errorOrNull, isA<Exception>());
      expect(calls, 4);
    });
  });
}
