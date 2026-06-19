import 'package:cachemesh/cachemesh.dart';
import 'package:test/test.dart';

class _FakeKeeper implements TokenKeeperAdapter {
  _FakeKeeper(this.token);
  final String token;
  @override
  Future<Result<T>> withValidToken<T>(AuthenticatedAction<T> action) =>
      action(token);
}

void main() {
  group('CacheEndpoint', () {
    late Cache cache;
    late int fetchCalls;
    late CacheEndpoint<int, String> ep;

    setUp(() {
      cache = Cache();
      fetchCalls = 0;
      ep = cache.endpoint<int, String>(
        key: (id) => 'item:$id',
        fetch: (id) async {
          fetchCalls++;
          return Success('item-$id');
        },
        policy: CachePolicy.cacheFirst,
      );
    });

    tearDown(() async => cache.dispose());

    test('call() reads through the cache; subsequent calls hit cache',
        () async {
      final a = await ep(1);
      final b = await ep(1);
      expect(a, const Success<String>('item-1'));
      expect(b, const Success<String>('item-1'));
      expect(fetchCalls, 1);
    });

    test('different params build different keys', () async {
      await ep(1);
      await ep(2);
      expect(fetchCalls, 2);
      expect(cache.peek<String>('item:1'), 'item-1');
      expect(cache.peek<String>('item:2'), 'item-2');
    });

    test('refresh forces a fetch and updates the cache', () async {
      await ep(1);
      await ep.refresh(1);
      expect(fetchCalls, 2);
    });

    test('peek/inspect/watch are routed through the built key', () async {
      await ep(1);
      expect(ep.peek(1), 'item-1');
      expect(ep.inspect(1).isFresh, isTrue);
      // watch contract: emits on writes after subscribe.
      final events = <Result<String>>[];
      final sub = ep.watch(1).listen(events.add);
      await ep.refresh(1);
      await Future<void>.delayed(Duration.zero);
      expect(events, [const Success<String>('item-1')]);
      await sub.cancel();
    });

    test('invalidate drops the entry for given params only', () async {
      await ep(1);
      await ep(2);
      ep.invalidate(1);
      expect(cache.peek<String>('item:1'), isNull);
      expect(cache.peek<String>('item:2'), 'item-2');
    });

    test('invalidateAll drops every key this endpoint touched', () async {
      await ep(1);
      await ep(2);
      await cache.refresh<int>(
          key: 'unrelated', fetch: () async => const Success(99));
      ep.invalidateAll();
      expect(cache.peek<String>('item:1'), isNull);
      expect(cache.peek<String>('item:2'), isNull);
      expect(cache.peek<int>('unrelated'), 99);
    });

    test('ownedKeys tracks the keys the endpoint has touched', () async {
      await ep(1);
      ep.peek(2); // peek does not own
      expect(ep.ownedKeys, contains('item:1'));
      expect(ep.ownedKeys, isNot(contains('item:2')));
    });
  });

  group('AuthenticatedCacheEndpoint', () {
    test('throws when no TokenKeeperAdapter is configured', () {
      final cache = Cache();
      expect(
        () => cache.authenticatedEndpoint<int, String>(
          key: (id) => 'k:$id',
          fetch: (id, _) async => const Success('x'),
        ),
        throwsStateError,
      );
    });

    test('routes the fetcher through withValidToken and caches per-user',
        () async {
      final keeper = _FakeKeeper('tok');
      final cache = Cache(tokenKeeper: keeper);
      cache.setActiveUser('alice');

      int calls = 0;
      final me = cache.authenticatedEndpoint<int, String>(
        key: (id) => 'me:$id',
        fetch: (id, token) async {
          calls++;
          return Success('me-$id($token)');
        },
      );

      final r1 = await me(1);
      final r2 = await me(1);
      expect(r1, const Success<String>('me-1(tok)'));
      expect(r2, const Success<String>('me-1(tok)'));
      expect(calls, 1);
      expect(cache.scopeOf('me:1'), CacheScope.user);
      await cache.dispose();
    });

    test('switching user wipes endpoint cache entries', () async {
      final cache = Cache(tokenKeeper: _FakeKeeper('tok'));
      cache.setActiveUser('alice');

      final me = cache.authenticatedEndpoint<int, String>(
        key: (id) => 'me:$id',
        fetch: (id, token) async => Success('me-$id'),
      );

      await me(1);
      cache.setActiveUser('bob');
      expect(cache.peek<String>('me:1'), isNull);
      await cache.dispose();
    });
  });
}
