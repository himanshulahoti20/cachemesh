import 'persisted_record.dart';

/// Async, restart-safe backing storage for the cache.
///
/// Unlike [CacheStore] (synchronous, in-memory hot path), a [PersistentStore]
/// is async and durable. The cache write-throughs to it and hydrates from it
/// on startup. Implement this for your storage backend of choice — a JSON
/// file ([JsonFileStore] in `package:cachemesh/cachemesh_io.dart`),
/// `shared_preferences`, Hive, sqflite, etc.
///
/// New in v1.2.0.
abstract interface class PersistentStore {
  /// Loads every persisted record. Called once on [Cache.hydrate].
  Future<List<PersistedRecord>> loadAll();

  /// Writes (or replaces) the record for `record.key`.
  Future<void> save(PersistedRecord record);

  /// Removes the record for [key], if present.
  Future<void> remove(String key);

  /// Removes every record.
  Future<void> clear();
}

/// A simple in-memory [PersistentStore] — useful for tests and demos.
///
/// "Persistent" only for the lifetime of the process; it does not survive a
/// restart. Swap in a real durable store in production.
class InMemoryPersistentStore implements PersistentStore {
  final Map<String, PersistedRecord> _records = {};

  /// Number of records currently held. Handy for assertions in tests.
  int get length => _records.length;

  @override
  Future<List<PersistedRecord>> loadAll() async => _records.values.toList();

  @override
  Future<void> save(PersistedRecord record) async {
    _records[record.key] = record;
  }

  @override
  Future<void> remove(String key) async {
    _records.remove(key);
  }

  @override
  Future<void> clear() async {
    _records.clear();
  }
}
