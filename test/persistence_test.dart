import 'package:cachemesh/cachemesh.dart';
import 'package:test/test.dart';

class _User {
  const _User(this.id, this.name);
  final int id;
  final String name;

  Map<String, dynamic> toJson() => {'id': id, 'name': name};
  factory _User.fromJson(Map<String, dynamic> j) =>
      _User(j['id'] as int, j['name'] as String);

  @override
  bool operator ==(Object other) =>
      other is _User && other.id == id && other.name == name;
  @override
  int get hashCode => Object.hash(id, name);
}

final _userCodec = CacheCodec<_User>(
  encode: (u) => u.toJson(),
  decode: (j) => _User.fromJson(j as Map<String, dynamic>),
);

class _Clock {
  DateTime now = DateTime(2026, 1, 1);
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

void main() {
  group('write-through + flush', () {
    test('successful writes are persisted to the store', () async {
      final disk = InMemoryPersistentStore();
      final cache = Cache(persistentStore: disk);
      cache.registerCodec<_User>('user:', _userCodec);

      await cache.refresh<_User>(
        key: 'user:1',
        fetch: () async => const Success(_User(1, 'Ada')),
      );
      await cache.flush();

      expect(disk.length, 1);
      final records = await disk.loadAll();
      expect(records.single.key, 'user:1');
      expect(records.single.value, {'id': 1, 'name': 'Ada'});
      await cache.dispose();
    });

    test('keys without a registered codec are NOT persisted', () async {
      final disk = InMemoryPersistentStore();
      final cache = Cache(persistentStore: disk);
      cache.registerCodec<_User>('user:', _userCodec);

      await cache.refresh<int>(
        key: 'counter:1',
        fetch: () async => const Success(5),
      );
      await cache.flush();

      expect(disk.length, 0);
      await cache.dispose();
    });

    test('failures are not persisted', () async {
      final disk = InMemoryPersistentStore();
      final cache = Cache(persistentStore: disk);
      cache.registerCodec<_User>('user:', _userCodec);

      await cache.get<_User>(
        key: 'user:1',
        fetch: () async => Failure<_User>('boom'),
        policy: CachePolicy.cacheFirst,
        cacheFailures: true,
      );
      await cache.flush();
      expect(disk.length, 0);
      await cache.dispose();
    });

    test('isPersistent reflects configuration', () {
      expect(Cache().isPersistent, isFalse);
      expect(Cache(persistentStore: InMemoryPersistentStore()).isPersistent,
          isTrue);
    });
  });

  group('hydrate', () {
    test('restores entries into memory on startup', () async {
      final disk = InMemoryPersistentStore();

      // Session 1: write and persist.
      final c1 = Cache(persistentStore: disk);
      c1.registerCodec<_User>('user:', _userCodec);
      await c1.refresh<_User>(
        key: 'user:1',
        fetch: () async => const Success(_User(1, 'Ada')),
      );
      await c1.flush();
      await c1.dispose();

      // Session 2: fresh cache over the same disk, hydrate.
      final c2 = Cache(persistentStore: disk);
      c2.registerCodec<_User>('user:', _userCodec);
      final restored = await c2.hydrate();

      expect(restored, 1);
      expect(c2.peek<_User>('user:1'), const _User(1, 'Ada'));
      await c2.dispose();
    });

    test('skips and prunes expired records', () async {
      final clock = _Clock();
      final disk = InMemoryPersistentStore();

      final c1 = Cache(persistentStore: disk, clock: clock.call);
      c1.registerCodec<_User>('user:', _userCodec);
      await c1.refresh<_User>(
        key: 'user:1',
        fetch: () async => const Success(_User(1, 'Ada')),
        ttl: const Duration(seconds: 5),
      );
      await c1.flush();
      await c1.dispose();

      clock.advance(const Duration(seconds: 10));

      final c2 = Cache(persistentStore: disk, clock: clock.call);
      c2.registerCodec<_User>('user:', _userCodec);
      final restored = await c2.hydrate();

      expect(restored, 0);
      expect(c2.peek<_User>('user:1'), isNull);
      // expired record pruned from disk
      await c2.flush();
      expect(disk.length, 0);
      await c2.dispose();
    });

    test('records without a matching codec are left on disk and not loaded',
        () async {
      final disk = InMemoryPersistentStore();
      await disk.save(PersistedRecord(
        key: 'orphan:1',
        value: 'x',
        createdAtMs: DateTime(2026).millisecondsSinceEpoch,
      ));

      final cache = Cache(persistentStore: disk);
      cache.registerCodec<_User>('user:', _userCodec);
      final restored = await cache.hydrate();

      expect(restored, 0);
      expect(disk.length, 1); // untouched
      await cache.dispose();
    });

    test('hydrate is a no-op without a persistent store', () async {
      final cache = Cache();
      expect(await cache.hydrate(), 0);
      await cache.dispose();
    });
  });

  group('invalidate / clear propagate to disk', () {
    test('invalidate removes the persisted record', () async {
      final disk = InMemoryPersistentStore();
      final cache = Cache(persistentStore: disk);
      cache.registerCodec<_User>('user:', _userCodec);

      await cache.refresh<_User>(
        key: 'user:1',
        fetch: () async => const Success(_User(1, 'Ada')),
      );
      await cache.flush();
      expect(disk.length, 1);

      cache.invalidate('user:1');
      await cache.flush();
      expect(disk.length, 0);
      await cache.dispose();
    });

    test('clear wipes the persistent store', () async {
      final disk = InMemoryPersistentStore();
      final cache = Cache(persistentStore: disk);
      cache.registerCodec<_User>('user:', _userCodec);

      await cache.refresh<_User>(
        key: 'user:1',
        fetch: () async => const Success(_User(1, 'Ada')),
      );
      await cache.flush();
      cache.clear();
      await cache.flush();
      expect(disk.length, 0);
      await cache.dispose();
    });
  });

  group('scope persistence + multi-user hydration', () {
    test('user-scoped records carry the userId and survive only for that user',
        () async {
      final disk = InMemoryPersistentStore();

      final c1 = Cache(persistentStore: disk);
      c1.registerCodec<_User>('user:', _userCodec);
      c1.setActiveUser('alice');
      await c1.refresh<_User>(
        key: 'user:me',
        fetch: () async => const Success(_User(1, 'Ada')),
        scope: CacheScope.user,
      );
      await c1.flush();
      await c1.dispose();

      // New session, hydrate, then bob logs in: alice's data must be cleared.
      final c2 = Cache(persistentStore: disk);
      c2.registerCodec<_User>('user:', _userCodec);
      await c2.hydrate();
      expect(c2.peek<_User>('user:me'), const _User(1, 'Ada'));
      expect(c2.scopeOf('user:me'), CacheScope.user);

      c2.setActiveUser('bob');
      expect(c2.peek<_User>('user:me'), isNull,
          reason: 'alice\'s hydrated data must not leak to bob');
      await c2.dispose();
    });
  });

  group('longest-prefix codec selection', () {
    test('most specific prefix wins', () async {
      final disk = InMemoryPersistentStore();
      final cache = Cache(persistentStore: disk);

      var usedGeneric = false;
      var usedSpecific = false;
      cache.registerCodec<int>(
        'user:',
        CacheCodec<int>(
          encode: (v) {
            usedGeneric = true;
            return v;
          },
          decode: (j) => j as int,
        ),
      );
      cache.registerCodec<int>(
        'user:admin:',
        CacheCodec<int>(
          encode: (v) {
            usedSpecific = true;
            return v;
          },
          decode: (j) => j as int,
        ),
      );

      await cache.refresh<int>(
        key: 'user:admin:1',
        fetch: () async => const Success(7),
      );
      await cache.flush();

      expect(usedSpecific, isTrue);
      expect(usedGeneric, isFalse);
      await cache.dispose();
    });
  });
}
