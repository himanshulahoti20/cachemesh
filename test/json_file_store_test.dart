@TestOn('vm')
library;

import 'dart:io';

import 'package:cachemesh/cachemesh.dart';
import 'package:cachemesh/cachemesh_io.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late JsonFileStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cachemesh_test_');
    store = JsonFileStore.atPath('${tempDir.path}/cache.json');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  PersistedRecord record(String key, Object? value) => PersistedRecord(
        key: key,
        value: value,
        createdAtMs: DateTime(2026).millisecondsSinceEpoch,
      );

  test('loadAll on a missing file returns empty', () async {
    expect(await store.loadAll(), isEmpty);
  });

  test('save then loadAll round-trips', () async {
    await store.save(record('user:1', {'name': 'Ada'}));
    final loaded = await store.loadAll();
    expect(loaded, hasLength(1));
    expect(loaded.single.key, 'user:1');
    expect(loaded.single.value, {'name': 'Ada'});
  });

  test('save overwrites an existing key', () async {
    await store.save(record('k', 1));
    await store.save(record('k', 2));
    final loaded = await store.loadAll();
    expect(loaded, hasLength(1));
    expect(loaded.single.value, 2);
  });

  test('remove deletes a record', () async {
    await store.save(record('a', 1));
    await store.save(record('b', 2));
    await store.remove('a');
    final loaded = await store.loadAll();
    expect(loaded.map((r) => r.key), ['b']);
  });

  test('clear empties the file', () async {
    await store.save(record('a', 1));
    await store.clear();
    expect(await store.loadAll(), isEmpty);
  });

  test('concurrent saves are serialized without data loss', () async {
    await Future.wait([
      for (var i = 0; i < 25; i++) store.save(record('k$i', i)),
    ]);
    final loaded = await store.loadAll();
    expect(loaded, hasLength(25));
  });

  test('survives a fresh store instance over the same file (persistence)',
      () async {
    await store.save(record('user:1', {'name': 'Ada'}));

    final reopened = JsonFileStore.atPath('${tempDir.path}/cache.json');
    final loaded = await reopened.loadAll();
    expect(loaded.single.value, {'name': 'Ada'});
  });

  test('end-to-end: Cache write-through to disk and hydrate from it', () async {
    final filePath = '${tempDir.path}/e2e.json';

    final c1 = Cache(persistentStore: JsonFileStore.atPath(filePath));
    c1.registerCodec<String>(
      'note:',
      CacheCodec<String>(encode: (s) => s, decode: (j) => j as String),
    );
    await c1.refresh<String>(
      key: 'note:1',
      fetch: () async => const Success('hello disk'),
    );
    await c1.flush();
    await c1.dispose();

    final c2 = Cache(persistentStore: JsonFileStore.atPath(filePath));
    c2.registerCodec<String>(
      'note:',
      CacheCodec<String>(encode: (s) => s, decode: (j) => j as String),
    );
    final restored = await c2.hydrate();
    expect(restored, 1);
    expect(c2.peek<String>('note:1'), 'hello disk');
    await c2.dispose();
  });
}
