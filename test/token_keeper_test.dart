import 'package:cachemesh/cachemesh.dart';
import 'package:test/test.dart';

/// A `TokenKeeperAdapter` that hands out the configured token, optionally
/// pretending the first call returned unauthorized so the action runs twice.
class _FakeTokenKeeper implements TokenKeeperAdapter {
  _FakeTokenKeeper({
    required this.token,
    this.refreshedToken,
    this.simulateUnauthorizedOnce = false,
  });

  final String token;
  final String? refreshedToken;
  bool simulateUnauthorizedOnce;

  int withValidTokenCalls = 0;
  final List<String> tokensSeen = [];

  @override
  Future<Result<T>> withValidToken<T>(AuthenticatedAction<T> action) async {
    withValidTokenCalls++;
    final first = await action(token);
    tokensSeen.add(token);

    if (simulateUnauthorizedOnce) {
      simulateUnauthorizedOnce = false;
      final refreshed = refreshedToken ?? token;
      tokensSeen.add(refreshed);
      return action(refreshed);
    }
    return first;
  }
}

class _Unauthorized implements Exception {
  const _Unauthorized();
}

void main() {
  group('getAuthenticated', () {
    test('throws StateError when no TokenKeeperAdapter is configured', () {
      final cache = Cache();
      cache.setActiveUser('alice');
      expect(
        () => cache.getAuthenticated<int>(
          key: 'k',
          fetch: (_) async => const Success(1),
        ),
        throwsStateError,
      );
    });

    test('routes the fetch through withValidToken', () async {
      final keeper = _FakeTokenKeeper(token: 'tok-abc');
      final cache = Cache(tokenKeeper: keeper);
      cache.setActiveUser('alice');

      final r = await cache.getAuthenticated<String>(
        key: 'me',
        fetch: (token) async => Success('hello($token)'),
      );

      expect(r, const Success<String>('hello(tok-abc)'));
      expect(keeper.withValidTokenCalls, 1);
      expect(keeper.tokensSeen, ['tok-abc']);
      await cache.dispose();
    });

    test('caches successful authenticated reads under user scope by default',
        () async {
      final keeper = _FakeTokenKeeper(token: 'tok');
      final cache = Cache(tokenKeeper: keeper);
      cache.setActiveUser('alice');

      int actionCalls = 0;
      Future<Result<int>> action(String token) async {
        actionCalls++;
        return const Success(1);
      }

      await cache.getAuthenticated<int>(key: 'me', fetch: action);
      await cache.getAuthenticated<int>(key: 'me', fetch: action);

      expect(actionCalls, 1, reason: 'second call should be a cache hit');
      expect(cache.scopeOf('me'), CacheScope.user);
      await cache.dispose();
    });

    test('switching user clears authenticated entries from previous user',
        () async {
      final keeper = _FakeTokenKeeper(token: 'tok-alice');
      final cache = Cache(tokenKeeper: keeper);
      cache.setActiveUser('alice');

      await cache.getAuthenticated<int>(
        key: 'me',
        fetch: (_) async => const Success(1),
      );
      expect(cache.peek<int>('me'), 1);

      cache.setActiveUser('bob');
      expect(cache.peek<int>('me'), isNull);
      await cache.dispose();
    });

    test('TokenKeeperAdapter is responsible for the retry-on-unauthorized loop',
        () async {
      final keeper = _FakeTokenKeeper(
        token: 'stale',
        refreshedToken: 'fresh',
        simulateUnauthorizedOnce: true,
      );
      final cache = Cache(tokenKeeper: keeper);
      cache.setActiveUser('alice');

      int actionCalls = 0;
      final r = await cache.getAuthenticated<String>(
        key: 'me',
        fetch: (token) async {
          actionCalls++;
          if (token == 'stale') return Failure<String>(const _Unauthorized());
          return Success<String>('ok($token)');
        },
      );

      expect(r, const Success<String>('ok(fresh)'));
      expect(actionCalls, 2);
      expect(keeper.tokensSeen, ['stale', 'fresh']);
      await cache.dispose();
    });

    test('caller can override the default user scope', () async {
      final keeper = _FakeTokenKeeper(token: 'tok');
      final cache = Cache(tokenKeeper: keeper);

      // Shared public-but-authenticated resource: keep across user switches.
      cache.setActiveUser('alice');
      await cache.getAuthenticated<int>(
        key: 'app-status',
        fetch: (_) async => const Success(1),
        scope: CacheScope.session,
      );

      cache.setActiveUser('bob');
      expect(cache.peek<int>('app-status'), 1,
          reason: 'session-scoped entries survive a user switch');
      await cache.dispose();
    });
  });
}
