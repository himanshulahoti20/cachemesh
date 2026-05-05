// Demonstrates v1.0.2 retry hooks and failure-aware caching.
//
// Run with:
//   dart run example/retry_and_failure_cache_example.dart

import 'package:cachemesh/cachemesh.dart';

// Simulates a flaky API: fails the first N calls, then succeeds.
class _FlakyApi {
  int _calls = 0;
  final int failUntil;
  _FlakyApi({this.failUntil = 2});

  Future<Result<String>> fetch(String key) async {
    _calls++;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    if (_calls <= failUntil) {
      print('  [api] call $_calls -> FAIL');
      return Failure<String>('network error (call $_calls)');
    }
    print('  [api] call $_calls -> OK');
    return Success<String>('data from call $_calls');
  }

  int get totalCalls => _calls;
}

// Error type that should NOT be retried (e.g. auth failure).
class UnauthorizedException implements Exception {
  const UnauthorizedException();
  @override
  String toString() => 'UnauthorizedException';
}

Future<void> main() async {
  await _demoRetry();
  await _demoRetryWhen();
  await _demoFailureCaching();
  await _demoRetryWithFailureCache();
}

// ── Retry: eventually succeeds ──────────────────────────────────────────────

Future<void> _demoRetry() async {
  print('\n=== retry: up to 5 attempts, succeeds on 3rd ===');
  final api = _FlakyApi(failUntil: 2);
  final cache = Cache(logger: const PrintCacheLogger(tag: 'retry'));

  final r = await cache.get<String>(
    key: 'data',
    fetch: () => api.fetch('data'),
    policy: CachePolicy.networkOnly,
    retryOptions: const RetryOptions(maxAttempts: 5),
  );

  print('result: ${r.valueOrNull} (total api calls: ${api.totalCalls})');
  await cache.dispose();
}

// ── retryWhen: skip retries on auth errors ───────────────────────────────────

Future<void> _demoRetryWhen() async {
  print('\n=== retryWhen: do not retry UnauthorizedException ===');
  int calls = 0;
  final cache = Cache();

  final r = await cache.get<String>(
    key: 'data',
    fetch: () async {
      calls++;
      print('  [api] call $calls -> UnauthorizedException');
      return Failure<String>(const UnauthorizedException());
    },
    policy: CachePolicy.networkOnly,
    retryOptions: RetryOptions(
      maxAttempts: 5,
      retryWhen: (e, _) => e is! UnauthorizedException,
    ),
  );

  print('result: ${r.errorOrNull} (total calls: $calls, expected 1)');
  await cache.dispose();
}

// ── Failure caching: avoid hammering the API ─────────────────────────────────

Future<void> _demoFailureCaching() async {
  print('\n=== failure caching: serve cached failure without hitting API ===');
  int calls = 0;
  final cache = Cache(logger: const PrintCacheLogger(tag: 'failcache'));

  // First call fails and stores the failure.
  final r1 = await cache.get<String>(
    key: 'data',
    fetch: () async {
      calls++;
      return Failure<String>('rate-limited');
    },
    policy: CachePolicy.cacheFirst,
    cacheFailures: true,
    ttl: const Duration(seconds: 30),
  );
  print('r1: ${r1.errorOrNull}  (api calls: $calls)');

  // Second call returns the cached failure — no network round-trip.
  final r2 = await cache.get<String>(
    key: 'data',
    fetch: () async {
      calls++;
      return Failure<String>('should not reach');
    },
    policy: CachePolicy.cacheFirst,
    cacheFailures: true,
  );
  print('r2: ${r2.errorOrNull}  (api calls: $calls, still 1)');
  print('hasCachedFailure: ${cache.hasCachedFailure('data')}');

  await cache.dispose();
}

// ── Combined: retry + failure caching ────────────────────────────────────────

Future<void> _demoRetryWithFailureCache() async {
  print('\n=== retry + failure caching combined ===');
  final api = _FlakyApi(failUntil: 10); // will always fail in this demo
  final cache = Cache(logger: const PrintCacheLogger(tag: 'combo'));

  // Exhaust retries; cache the final failure.
  final r1 = await cache.get<String>(
    key: 'data',
    fetch: () => api.fetch('data'),
    policy: CachePolicy.cacheFirst,
    cacheFailures: true,
    ttl: const Duration(seconds: 5),
    retryOptions: const RetryOptions(maxAttempts: 3),
  );
  print(
    'r1: ${r1.errorOrNull}  (api calls: ${api.totalCalls}, '
    'hasCachedFailure: ${cache.hasCachedFailure('data')})',
  );

  // Next call returns the cached failure with zero retries.
  final r2 = await cache.get<String>(
    key: 'data',
    fetch: () => api.fetch('data'),
    policy: CachePolicy.cacheFirst,
    cacheFailures: true,
    retryOptions: const RetryOptions(maxAttempts: 3),
  );
  print(
    'r2: ${r2.errorOrNull}  (api calls: ${api.totalCalls}, still 3)',
  );

  await cache.dispose();
}
