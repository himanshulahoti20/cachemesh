// Demonstrates every cachemesh CachePolicy.
//
// Run with:
//   dart run example/policies_example.dart

import 'package:cachemesh/cachemesh.dart';

int _calls = 0;
Future<Result<String>> fetch(String label) async {
  _calls++;
  await Future<void>.delayed(const Duration(milliseconds: 20));
  return Success('$label#$_calls');
}

Future<void> main() async {
  await _demoCacheFirst();
  await _demoNetworkFirst();
  await _demoNetworkOnly();
  await _demoCacheOnly();
  await _demoStaleWhileRevalidate();
}

Future<void> _demoCacheFirst() async {
  print('\n--- cacheFirst ---');
  _calls = 0;
  final cache = Cache();
  final a = await cache.get<String>(
    key: 'k',
    fetch: () => fetch('A'),
    policy: CachePolicy.cacheFirst,
  );
  final b = await cache.get<String>(
    key: 'k',
    fetch: () => fetch('B'),
    policy: CachePolicy.cacheFirst,
  );
  print('a=${a.valueOrNull}, b=${b.valueOrNull}, calls=$_calls');
  await cache.dispose();
}

Future<void> _demoNetworkFirst() async {
  print('\n--- networkFirst (with fallback) ---');
  _calls = 0;
  final cache = Cache();
  await cache.get<String>(
    key: 'k',
    fetch: () => fetch('A'),
    policy: CachePolicy.networkFirst,
  );
  // Now simulate "offline": failing fetcher should fall back to cache.
  final b = await cache.get<String>(
    key: 'k',
    fetch: () async => Failure<String>('offline'),
    policy: CachePolicy.networkFirst,
  );
  print('fallback=${b.valueOrNull}, calls=$_calls');
  await cache.dispose();
}

Future<void> _demoNetworkOnly() async {
  print('\n--- networkOnly ---');
  _calls = 0;
  final cache = Cache();
  await cache.get<String>(
    key: 'k',
    fetch: () => fetch('A'),
    policy: CachePolicy.networkOnly,
  );
  await cache.get<String>(
    key: 'k',
    fetch: () => fetch('B'),
    policy: CachePolicy.networkOnly,
  );
  print('peek=${cache.peek<String>('k')} (always null), calls=$_calls');
  await cache.dispose();
}

Future<void> _demoCacheOnly() async {
  print('\n--- cacheOnly ---');
  final cache = Cache();
  final miss = await cache.get<String>(
    key: 'never-fetched',
    fetch: () => fetch('X'),
    policy: CachePolicy.cacheOnly,
  );
  print('miss => ${miss.errorOrNull?.runtimeType}');

  await cache.prefetch<String>(key: 'k', fetch: () => fetch('A'));
  final hit = await cache.get<String>(
    key: 'k',
    fetch: () => fetch('X'),
    policy: CachePolicy.cacheOnly,
  );
  print('hit  => ${hit.valueOrNull}');
  await cache.dispose();
}

Future<void> _demoStaleWhileRevalidate() async {
  print('\n--- staleWhileRevalidate ---');
  _calls = 0;
  final cache = Cache();
  await cache.prefetch<String>(key: 'k', fetch: () => fetch('A'));

  final r = await cache.get<String>(
    key: 'k',
    fetch: () => fetch('B'),
    policy: CachePolicy.staleWhileRevalidate,
  );
  print('returned immediately: ${r.valueOrNull}');

  // Wait for the background refresh.
  await Future<void>.delayed(const Duration(milliseconds: 100));
  print('after bg refresh: ${cache.peek<String>('k')}, calls=$_calls');
  await cache.dispose();
}
