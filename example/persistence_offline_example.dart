// Demonstrates v1.2.0 persistence, hydration, offline-first, and metrics.
//
// Run with:
//   dart run example/persistence_offline_example.dart

import 'dart:io';

import 'package:cachemesh/cachemesh.dart';
import 'package:cachemesh/cachemesh_io.dart';

class Article {
  const Article(this.id, this.title);
  final int id;
  final String title;

  Map<String, dynamic> toJson() => {'id': id, 'title': title};
  factory Article.fromJson(Map<String, dynamic> j) =>
      Article(j['id'] as int, j['title'] as String);

  @override
  String toString() => 'Article($id, "$title")';
}

final articleCodec = CacheCodec<Article>(
  encode: (a) => a.toJson(),
  decode: (j) => Article.fromJson(j as Map<String, dynamic>),
);

/// Simulates a network that can be toggled offline.
class FakeApi {
  bool online = true;
  int calls = 0;

  Future<Result<Article>> fetchArticle(int id) async {
    calls++;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    if (!online) return Failure<Article>('offline');
    return Success(Article(id, 'Fresh article #$id (call $calls)'));
  }
}

Future<void> main() async {
  final dir = await Directory.systemTemp.createTemp('cachemesh_demo_');
  final path = '${dir.path}/cache.json';
  final api = FakeApi();

  try {
    await _session1(path, api);
    await _session2Offline(path, api);
  } finally {
    await dir.delete(recursive: true);
  }
}

// First app launch: cold cache, fetch + persist to disk.
Future<void> _session1(String path, FakeApi api) async {
  print('=== Session 1: cold start, online ===');
  final cache = Cache(persistentStore: JsonFileStore.atPath(path));
  cache.registerCodec<Article>('article:', articleCodec);

  final restored = await cache.hydrate();
  print('hydrated $restored entries (expected 0 on first run)');

  final r = await cache.get<Article>(
    key: 'article:1',
    fetch: () => api.fetchArticle(1),
    policy: CachePolicy.networkFirst,
    ttl: const Duration(hours: 1),
  );
  print('fetched: ${r.valueOrNull}');

  await cache.flush(); // make sure it hit the disk
  print('metrics: ${cache.metrics}');
  await cache.dispose();
}

// Second app launch: hydrate from disk, then go offline.
Future<void> _session2Offline(String path, FakeApi api) async {
  print('\n=== Session 2: restart, then offline ===');
  final cache = Cache(persistentStore: JsonFileStore.atPath(path));
  cache.registerCodec<Article>('article:', articleCodec);

  final restored = await cache.hydrate();
  print('hydrated $restored entries from the previous session');
  print('peek (no fetch): ${cache.peek<Article>('article:1')}');

  // Network is down — networkFirst falls back to the hydrated cache.
  api.online = false;
  final r = await cache.get<Article>(
    key: 'article:1',
    fetch: () => api.fetchArticle(1),
    policy: CachePolicy.networkFirst,
  );
  print('offline read served from cache: ${r.valueOrNull}');

  // A brand-new key with no cache + offline network => failure.
  final miss = await cache.get<Article>(
    key: 'article:999',
    fetch: () => api.fetchArticle(999),
    policy: CachePolicy.networkFirst,
  );
  print('offline read with no cache: ${miss.errorOrNull}');

  print('metrics: ${cache.metrics}');
  await cache.dispose();
}
