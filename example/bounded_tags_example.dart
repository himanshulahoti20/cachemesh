import 'package:cachemesh/cachemesh.dart';

/// v2.1.0 — LRU bounds, tags, direct writes, and watch(emitCurrent).
Future<void> main() async {
  final cache = Cache(maxEntries: 3, logger: const PrintCacheLogger());

  // Tag entries, then invalidate by tag.
  for (final id in [1, 2]) {
    await cache.get<String>(
      key: 'feed:$id',
      fetch: () async => Success('feed #$id'),
      tags: {'feed'},
    );
  }
  cache.set<String>('profile', 'Ada', tags: {'user'});
  print('tags of feed:1 -> ${cache.tagsOf('feed:1')}');

  // Over capacity: the least recently used entry (feed:1) is evicted.
  cache.set<String>('extra', 'x');
  print('keys after eviction -> ${cache.allKeys.toList()}');

  // watch(emitCurrent) delivers the cached value immediately.
  final sub = cache
      .watch<String>('profile', emitCurrent: true)
      .listen((r) => print('profile -> $r'));
  cache.update<String>('profile', (n) => '$n Lovelace'); // optimistic edit
  await Future<void>.delayed(Duration.zero);

  print('dropped by tag -> ${cache.invalidateTag('feed')}');
  await sub.cancel();
  await cache.dispose();
}
