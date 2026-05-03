import 'cache_entry.dart';

/// Backing storage for [CacheEntry] values, keyed by string.
///
/// v1.0.0 ships [MemoryCacheStore] only; persistent adapters land in v1.2.0.
/// The interface intentionally stays small so swapping in a disk-backed store
/// later is non-breaking.
abstract interface class CacheStore {
  /// Returns the entry for [key] or `null` if absent.
  CacheEntry<dynamic>? read(String key);

  /// Writes [entry] under [key], replacing any prior entry.
  void write(String key, CacheEntry<dynamic> entry);

  /// Removes the entry for [key], if any.
  void delete(String key);

  /// Removes every entry from the store.
  void clear();

  /// All currently stored keys.
  Iterable<String> keys();

  /// `true` if [key] is present (regardless of expiration).
  bool contains(String key);
}
