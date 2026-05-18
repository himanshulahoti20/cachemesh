import 'package:cachemesh/cachemesh.dart';
import 'package:test/test.dart';

void main() {
  late Cache cache;

  setUp(() => cache = Cache());
  tearDown(() async => cache.dispose());

  group('default scope', () {
    test('entries without an explicit scope are global', () async {
      await cache.refresh<int>(
        key: 'config',
        fetch: () async => const Success<int>(1),
      );
      expect(cache.scopeOf('config'), CacheScope.global);
    });

    test('scopeOf returns global for unknown keys', () {
      expect(cache.scopeOf('never-touched'), CacheScope.global);
    });
  });

  group('CacheScope.session', () {
    test('endSession drops session-scoped entries and keeps global', () async {
      await cache.refresh<int>(
        key: 'session-data',
        fetch: () async => const Success<int>(1),
        scope: CacheScope.session,
      );
      await cache.refresh<int>(
        key: 'app-config',
        fetch: () async => const Success<int>(42),
        scope: CacheScope.global,
      );

      cache.endSession();

      expect(cache.peek<int>('session-data'), isNull);
      expect(cache.peek<int>('app-config'), 42);
      expect(cache.scopeOf('session-data'), CacheScope.global); // forgotten
    });

    test('clearScope(session) drops only session entries', () async {
      cache.setActiveUser('u1');
      await cache.refresh<int>(
        key: 's',
        fetch: () async => const Success<int>(1),
        scope: CacheScope.session,
      );
      await cache.refresh<int>(
        key: 'u',
        fetch: () async => const Success<int>(2),
        scope: CacheScope.user,
      );

      cache.clearScope(CacheScope.session);

      expect(cache.peek<int>('s'), isNull);
      expect(cache.peek<int>('u'), 2);
    });
  });

  group('CacheScope.user', () {
    test('throws when no active user is set', () {
      expect(
        () => cache.refresh<int>(
          key: 'k',
          fetch: () async => const Success<int>(1),
          scope: CacheScope.user,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('setActiveUser clears entries tied to the previous user', () async {
      cache.setActiveUser('alice');
      await cache.refresh<int>(
        key: 'profile',
        fetch: () async => const Success<int>(1),
        scope: CacheScope.user,
      );
      expect(cache.peek<int>('profile'), 1);
      expect(cache.activeUserId, 'alice');

      cache.setActiveUser('bob');
      expect(cache.activeUserId, 'bob');
      expect(
        cache.peek<int>('profile'),
        isNull,
        reason: 'alice\'s data must not be visible after switch',
      );
    });

    test('setActiveUser is a no-op when the user does not change', () async {
      cache.setActiveUser('alice');
      await cache.refresh<int>(
        key: 'profile',
        fetch: () async => const Success<int>(1),
        scope: CacheScope.user,
      );
      cache.setActiveUser('alice');
      expect(cache.peek<int>('profile'), 1);
    });

    test('endSession clears user entries and unsets the active user', () async {
      cache.setActiveUser('alice');
      await cache.refresh<int>(
        key: 'profile',
        fetch: () async => const Success<int>(1),
        scope: CacheScope.user,
      );

      cache.endSession();
      expect(cache.activeUserId, isNull);
      expect(cache.peek<int>('profile'), isNull);
    });

    test('setActiveUser(null) clears the previous user\'s entries', () async {
      cache.setActiveUser('alice');
      await cache.refresh<int>(
        key: 'profile',
        fetch: () async => const Success<int>(1),
        scope: CacheScope.user,
      );

      cache.setActiveUser(null);
      expect(cache.activeUserId, isNull);
      expect(cache.peek<int>('profile'), isNull);
    });
  });

  group('logger emits onScopeCleared', () {
    test('reports the reason and removed keys', () async {
      final events = <(String, List<String>)>[];
      final logger = _RecordingLogger((reason, keys) {
        events.add((reason, List.of(keys)));
      });
      final cache = Cache(logger: logger);
      cache.setActiveUser('alice');
      await cache.refresh<int>(
        key: 'k',
        fetch: () async => const Success<int>(1),
        scope: CacheScope.user,
      );

      cache.setActiveUser('bob');
      cache.endSession();

      expect(events, isNotEmpty);
      expect(events.first.$1, 'setActiveUser');
      expect(events.first.$2, contains('k'));
      await cache.dispose();
    });
  });

  group('invalidate cleans up scope tracking', () {
    test('invalidate removes scope metadata so scopeOf forgets it', () async {
      cache.setActiveUser('alice');
      await cache.refresh<int>(
        key: 'k',
        fetch: () async => const Success<int>(1),
        scope: CacheScope.user,
      );
      cache.invalidate('k');
      expect(cache.scopeOf('k'), CacheScope.global);
    });
  });

  group('failure caching respects scope', () {
    test(
      'cached failures under session scope are cleared by endSession',
      () async {
        await cache.get<int>(
          key: 'k',
          fetch: () async => Failure<int>('boom'),
          policy: CachePolicy.cacheFirst,
          cacheFailures: true,
          scope: CacheScope.session,
        );
        expect(cache.hasCachedFailure('k'), isTrue);

        cache.endSession();
        expect(cache.hasCachedFailure('k'), isFalse);
      },
    );
  });
}

class _RecordingLogger extends CacheLogger {
  _RecordingLogger(this._onScope);
  final void Function(String reason, List<String> keys) _onScope;

  @override
  void onScopeCleared(String reason, List<String> removedKeys) =>
      _onScope(reason, removedKeys);
}
