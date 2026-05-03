import 'cache_entry.dart';
import 'cache_store.dart';

/// Default [CacheStore]: an in-memory map with TTL-based expiration.
///
/// Fast, dependency-free, and lost on app restart. For restart-safe caching
/// see the disk adapters added in v1.2.0.
class MemoryCacheStore implements CacheStore {
  final Map<String, CacheEntry<dynamic>> _entries = {};

  @override
  CacheEntry<dynamic>? read(String key) => _entries[key];

  @override
  void write(String key, CacheEntry<dynamic> entry) {
    _entries[key] = entry;
  }

  @override
  void delete(String key) {
    _entries.remove(key);
  }

  @override
  void clear() {
    _entries.clear();
  }

  @override
  Iterable<String> keys() => _entries.keys;

  @override
  bool contains(String key) => _entries.containsKey(key);
}
