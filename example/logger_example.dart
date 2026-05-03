// Demonstrates the v1.0.1 CacheLogger.
//
// Run with:
//   dart run example/logger_example.dart

import 'package:cachemesh/cachemesh.dart';

/// Minimal custom logger that only cares about misses and errors.
class MetricsLogger extends CacheLogger {
  int misses = 0;
  int errors = 0;

  @override
  void onMiss(String key) => misses++;

  @override
  void onError(String key, Object error, StackTrace? stackTrace) {
    errors++;
    print('[metrics] error on $key: $error');
  }
}

Future<void> main() async {
  print('--- with PrintCacheLogger ---');
  final printed = Cache(logger: const PrintCacheLogger(tag: 'demo'));
  await printed.get<int>(
    key: 'a',
    fetch: () async => const Success(1),
    policy: CachePolicy.cacheFirst,
    ttl: const Duration(seconds: 30),
  );
  await printed.get<int>(
    key: 'a',
    fetch: () async => const Success(2),
    policy: CachePolicy.cacheFirst,
  );
  await printed.refresh<int>(key: 'a', fetch: () async => Failure<int>('boom'));
  printed.invalidate('a');
  printed.clear();
  await printed.dispose();

  print('\n--- with custom MetricsLogger ---');
  final metrics = MetricsLogger();
  final cache = Cache(logger: metrics);
  await cache.get<int>(
    key: 'b',
    fetch: () async => const Success(1),
    policy: CachePolicy.cacheFirst,
  );
  await cache.refresh<int>(key: 'b', fetch: () async => Failure<int>('nope'));
  print('misses=${metrics.misses}, errors=${metrics.errors}');
  await cache.dispose();
}
