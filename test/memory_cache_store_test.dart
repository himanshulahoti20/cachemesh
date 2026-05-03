import 'package:cachemesh/cachemesh.dart';
import 'package:test/test.dart';

void main() {
  group('MemoryCacheStore', () {
    late MemoryCacheStore store;

    setUp(() => store = MemoryCacheStore());

    test('write/read roundtrip', () {
      final entry = CacheEntry<int>(value: 1, createdAt: DateTime(2026));
      store.write('a', entry);
      expect(store.read('a'), entry);
      expect(store.contains('a'), isTrue);
      expect(store.keys(), contains('a'));
    });

    test('delete removes the entry', () {
      store.write('a', CacheEntry<int>(value: 1, createdAt: DateTime(2026)));
      store.delete('a');
      expect(store.read('a'), isNull);
      expect(store.contains('a'), isFalse);
    });

    test('clear empties the store', () {
      store.write('a', CacheEntry<int>(value: 1, createdAt: DateTime(2026)));
      store.write('b', CacheEntry<int>(value: 2, createdAt: DateTime(2026)));
      store.clear();
      expect(store.keys(), isEmpty);
    });
  });

  group('CacheEntry', () {
    test('no ttl => never expired', () {
      final entry = CacheEntry<int>(value: 1, createdAt: DateTime(2026));
      expect(entry.isExpiredAt(DateTime(2030)), isFalse);
      expect(entry.expiresAt, isNull);
    });

    test('within ttl => not expired', () {
      final entry = CacheEntry<int>(
        value: 1,
        createdAt: DateTime(2026, 1, 1),
        ttl: const Duration(minutes: 10),
      );
      expect(entry.isExpiredAt(DateTime(2026, 1, 1, 0, 5)), isFalse);
    });

    test('past ttl => expired', () {
      final entry = CacheEntry<int>(
        value: 1,
        createdAt: DateTime(2026, 1, 1),
        ttl: const Duration(minutes: 10),
      );
      expect(entry.isExpiredAt(DateTime(2026, 1, 1, 0, 11)), isTrue);
    });
  });
}
