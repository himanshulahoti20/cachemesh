// Demonstrates v1.1.0 ecosystem integration:
// - ResilifySource (any Future<Result<T>> plugs in directly)
// - TokenKeeperAdapter + Cache.getAuthenticated
// - CacheScope.global / session / user
// - setActiveUser, endSession, clearScope
//
// Run with:
//   dart run example/scopes_and_auth_example.dart

import 'package:cachemesh/cachemesh.dart';

// ─── Fake auth + API for the demo ───────────────────────────────────────────

/// A pretend token_keeper adapter. In a real app this would delegate to your
/// `token_keeper` instance's `withValidToken` (which transparently refreshes
/// on unauthorized and retries the action once).
class FakeTokenKeeperAdapter implements TokenKeeperAdapter {
  FakeTokenKeeperAdapter(this._tokenForUser);
  final String Function() _tokenForUser;

  @override
  Future<Result<T>> withValidToken<T>(AuthenticatedAction<T> action) =>
      action(_tokenForUser());
}

/// A pretend resilify-backed API.
///
/// `feed()` and `appConfig()` are plain `ResilifySource`s (no auth).
/// `me(token)` is an `AuthenticatedAction` — takes a token and returns the
/// result directly, so it can be passed to `cache.getAuthenticated(fetch: ...)`.
class FakeApi {
  int calls = 0;

  Future<Result<Map<String, String>>> me(String token) async {
    calls++;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return Success({'token': token, 'name': 'User of $token'});
  }

  ResilifySource<List<String>> feed() => () async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return Success<List<String>>(const ['post-1', 'post-2']);
      };

  ResilifySource<String> appConfig() => () async {
        calls++;
        return const Success('dark-mode=true');
      };
}

// ─── Demo ───────────────────────────────────────────────────────────────────

Future<void> main() async {
  String activeUser = 'alice';
  final keeper = FakeTokenKeeperAdapter(() => 'tok-$activeUser');
  final api = FakeApi();
  final cache = Cache(
    logger: const PrintCacheLogger(tag: 'cachemesh'),
    tokenKeeper: keeper,
  );

  print('\n=== Resilify: plug fetchers in directly (no wrapping) ===');
  final cfg = await cache.get<String>(
    key: 'app:config',
    fetch: api.appConfig(),
    scope: CacheScope.global,
  );
  print('config => ${cfg.valueOrNull}');

  print('\n=== Authenticated read for alice ===');
  cache.setActiveUser('alice');
  final me1 = await cache.getAuthenticated<Map<String, String>>(
    key: 'me',
    fetch: api.me,
  );
  print('me => ${me1.valueOrNull}');

  print('\n=== Session-scoped feed ===');
  await cache.get<List<String>>(
    key: 'feed',
    fetch: api.feed(),
    scope: CacheScope.session,
  );

  print('\n=== Second authenticated read is a cache hit ===');
  final me2 = await cache.getAuthenticated<Map<String, String>>(
    key: 'me',
    fetch: api.me,
  );
  print('me again => ${me2.valueOrNull}   (api.calls=${api.calls})');

  print('\n=== Switch user → alice\'s personal data is wiped ===');
  activeUser = 'bob';
  cache.setActiveUser('bob');
  print('peek me (should be null): ${cache.peek<Map<String, String>>('me')}');
  print(
      'peek feed (session — still there): ${cache.peek<List<String>>('feed')}');
  print(
      'peek config (global — still there): ${cache.peek<String>('app:config')}');

  print('\n=== bob fetches his own profile ===');
  final me3 = await cache.getAuthenticated<Map<String, String>>(
    key: 'me',
    fetch: api.me,
  );
  print('me => ${me3.valueOrNull}');
  print('scopeOf("me") => ${cache.scopeOf('me')}');

  print('\n=== Logout: endSession wipes session + user, keeps globals ===');
  cache.endSession();
  print('activeUserId => ${cache.activeUserId}');
  print('peek me: ${cache.peek<Map<String, String>>('me')}');
  print('peek feed: ${cache.peek<List<String>>('feed')}');
  print('peek config (global): ${cache.peek<String>('app:config')}');

  await cache.dispose();
}
