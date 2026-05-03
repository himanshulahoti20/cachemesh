// Demonstrates reactive subscriptions with Cache.watch().
//
// Run with:
//   dart run example/watch_example.dart

import 'package:cachemesh/cachemesh.dart';

Future<void> main() async {
  final cache = Cache();

  final sub = cache.watch<int>('counter').listen((result) {
    result.fold(
      onSuccess: (v) => print('watcher saw: $v'),
      onFailure: (e, _) => print('watcher saw error: $e'),
    );
  });

  // Each successful write to 'counter' fans out to subscribers.
  await cache.refresh<int>(key: 'counter', fetch: () async => const Success(1));
  await cache.refresh<int>(key: 'counter', fetch: () async => const Success(2));

  // Pre-populate then use SWR — the background refresh fires a second emission.
  await cache.refresh<int>(key: 'counter', fetch: () async => const Success(3));
  await cache.get<int>(
    key: 'counter',
    fetch: () async => const Success(4),
    policy: CachePolicy.staleWhileRevalidate,
  );
  await Future<void>.delayed(const Duration(milliseconds: 50));

  await sub.cancel();
  await cache.dispose();
}
