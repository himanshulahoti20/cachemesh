// Demonstrates v2.0.0 unified data engine: endpoints, reactive combine,
// authenticated endpoints, and dev tooling.
//
// Run with:
//   dart run example/unified_data_engine_example.dart

import 'package:cachemesh/cachemesh.dart';

// ─── Fake API + token keeper ────────────────────────────────────────────────

class User {
  const User(this.id, this.name);
  final int id;
  final String name;
  @override
  String toString() => 'User($id, $name)';
}

class Post {
  const Post(this.id, this.title);
  final int id;
  final String title;
  @override
  String toString() => 'Post($id, "$title")';
}

class FakeKeeper implements TokenKeeperAdapter {
  FakeKeeper(this.tokenFor);
  final String Function() tokenFor;
  @override
  Future<Result<T>> withValidToken<T>(AuthenticatedAction<T> action) =>
      action(tokenFor());
}

class FakeApi {
  int calls = 0;

  Future<Result<User>> fetchUser(int id, String token) async {
    calls++;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return Success(User(id, 'User #$id (auth=$token)'));
  }

  Future<Result<List<Post>>> fetchPosts(int userId) async {
    calls++;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return Success(
      List.generate(2, (i) => Post(i, 'Post $i by user $userId')),
    );
  }
}

// ─── Demo ───────────────────────────────────────────────────────────────────

Future<void> main() async {
  String activeUser = 'alice';
  final keeper = FakeKeeper(() => 'tok-$activeUser');
  final api = FakeApi();
  final cache = Cache(
    tokenKeeper: keeper,
    logger: const PrintCacheLogger(tag: 'engine'),
  );

  // 1) Define endpoints ONCE.
  final users = cache.authenticatedEndpoint<int, User>(
    key: (id) => 'user:$id',
    fetch: api.fetchUser,
    policy: CachePolicy.cacheFirst,
    ttl: const Duration(minutes: 5),
  );
  final posts = cache.endpoint<int, List<Post>>(
    key: (userId) => 'posts:$userId',
    fetch: (userId) => api.fetchPosts(userId),
    policy: CachePolicy.staleWhileRevalidate,
    ttl: const Duration(minutes: 1),
  );

  cache.setActiveUser(activeUser);

  // 2) Use them anywhere.
  print('\n=== first reads (cache miss → fetch → cache) ===');
  print(await users(1));
  print(await posts(1));

  print('\n=== second reads (cache hit) ===');
  print(await users(1));
  print(await posts(1));
  print('total api calls so far: ${api.calls}  (expected 2)');

  // 3) Reactive combine — react to multiple keys at once.
  print('\n=== reactive combine: user + posts → "profile" ===');
  final profileStream = cache.combineLatest<String>(
    ['user:1', 'posts:1'],
    (vs) {
      final u = vs[0] as User;
      final ps = vs[1] as List<Post>;
      return '${u.name} has ${ps.length} posts';
    },
  );
  final sub = profileStream.listen(
    (r) => print('  profile => ${r.valueOrNull}'),
  );
  // First emission is the seeded current value.
  await Future<void>.delayed(const Duration(milliseconds: 10));

  // Update one of the keys: the combined stream re-fires.
  await users.refresh(1);
  await Future<void>.delayed(const Duration(milliseconds: 10));
  await sub.cancel();

  // 4) Switch user → endpoint-owned, user-scoped keys are dropped.
  print('\n=== switch user → bob ===');
  activeUser = 'bob';
  cache.setActiveUser('bob');
  print('peek user:1 (alice\'s, gone): ${cache.peek<User>('user:1')}');
  print('peek posts:1 (global, kept):  ${cache.peek<List<Post>>('posts:1')}');

  // 5) Endpoint-scoped bulk invalidate.
  print('\n=== posts.invalidateAll() — only posts entries dropped ===');
  posts.invalidateAll();
  print('peek posts:1: ${cache.peek<List<Post>>('posts:1')}');

  // 6) Dev tooling — debug dump + metrics.
  print('\n=== debugDump ===');
  print(cache.debugDump());

  await cache.dispose();
}
