import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'persisted_record.dart';
import 'persistent_store.dart';

/// A [PersistentStore] that writes all records to a single JSON file.
///
/// Backed by `dart:io`, so it works on the Dart VM, Flutter mobile, and
/// desktop — **not** the web. It is exported from
/// `package:cachemesh/cachemesh_io.dart` (not the default barrel) precisely so
/// importing the core library never drags in `dart:io`.
///
/// Operations are serialized through an internal lock so concurrent
/// write-throughs from the cache can't corrupt the file. The whole file is
/// rewritten on each mutation — appropriate for the modest data sizes a
/// client-side cache holds, not a high-write server store.
///
/// New in v1.2.0.
class JsonFileStore implements PersistentStore {
  JsonFileStore(this.file);

  /// Convenience constructor from a filesystem path.
  JsonFileStore.atPath(String path) : file = File(path);

  /// The file all records are written to.
  final File file;

  Future<void> _lock = Future<void>.value();

  /// Serializes [action] after any in-flight operation to avoid interleaved
  /// read-modify-write races on [file].
  Future<R> _synchronized<R>(Future<R> Function() action) {
    final completer = Completer<R>();
    _lock = _lock.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<Map<String, dynamic>> _readRaw() async {
    if (!await file.exists()) return {};
    final content = await file.readAsString();
    if (content.trim().isEmpty) return {};
    final decoded = jsonDecode(content);
    if (decoded is! Map<String, dynamic>) return {};
    return decoded;
  }

  Future<void> _writeRaw(Map<String, dynamic> raw) async {
    final parent = file.parent;
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }
    await file.writeAsString(jsonEncode(raw));
  }

  @override
  Future<List<PersistedRecord>> loadAll() => _synchronized(() async {
        final raw = await _readRaw();
        return raw.values
            .whereType<Map<String, dynamic>>()
            .map(PersistedRecord.fromJson)
            .toList();
      });

  @override
  Future<void> save(PersistedRecord record) => _synchronized(() async {
        final raw = await _readRaw();
        raw[record.key] = record.toJson();
        await _writeRaw(raw);
      });

  @override
  Future<void> remove(String key) => _synchronized(() async {
        final raw = await _readRaw();
        if (raw.remove(key) != null) {
          await _writeRaw(raw);
        }
      });

  @override
  Future<void> clear() => _synchronized(() async {
        if (await file.exists()) {
          await file.writeAsString('{}');
        }
      });
}
