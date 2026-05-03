// Demonstrates the v1.0.1 Cache.inspect() state insights.
//
// Run with:
//   dart run example/inspect_example.dart

import 'package:cachemesh/cachemesh.dart';

void describe(String label, CacheState state) {
  print('$label  =>  $state');
}

Future<void> main() async {
  final cache = Cache();

  describe('missing', cache.inspect<String>('user:1'));

  await cache.prefetch<String>(
    key: 'user:1',
    fetch: () async => const Success('Ada'),
    ttl: const Duration(milliseconds: 100),
  );

  describe('just written', cache.inspect<String>('user:1'));

  await Future<void>.delayed(const Duration(milliseconds: 50));
  describe('mid-life', cache.inspect<String>('user:1'));

  await Future<void>.delayed(const Duration(milliseconds: 80));
  final stale = cache.inspect<String>('user:1');
  describe('past ttl', stale);
  print('stale.isStale=${stale.isStale}, '
      'value=${stale.value}, '
      'expired ${stale.timeToExpiry!.abs().inMilliseconds}ms ago');

  await cache.dispose();
}
