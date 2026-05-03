// Quick-start example for cachemesh.
//
// Run with:
//   dart run example/cachemesh_example.dart
//
// The other example files in this directory demonstrate individual features:
//   policies_example.dart  — every CachePolicy in action
//   watch_example.dart     — reactive watch() streams
//   logger_example.dart    — pluggable CacheLogger (v1.0.1)
//   inspect_example.dart   — Cache.inspect() state insights (v1.0.1)

import 'package:cachemesh/cachemesh.dart';

class User {
  User(this.id, this.name);
  final int id;
  final String name;
  @override
  String toString() => 'User($id, $name)';
}

// Pretend network call. In a real app this would be `resilify` or your http client.
int _calls = 0;
Future<Result<User>> fetchUser(int id) async {
  _calls++;
  await Future<void>.delayed(const Duration(milliseconds: 50));
  return Success(User(id, 'Ada $_calls'));
}

Future<void> main() async {
  final cache = Cache(logger: const PrintCacheLogger());

  // First call: cache miss → fetch → cache.
  final r1 = await cache.get<User>(
    key: 'user:1',
    fetch: () => fetchUser(1),
    policy: CachePolicy.cacheFirst,
    ttl: const Duration(minutes: 5),
  );
  print('first  => ${r1.valueOrNull}');

  // Second call within TTL: cache hit, no fetch.
  final r2 = await cache.get<User>(
    key: 'user:1',
    fetch: () => fetchUser(1),
    policy: CachePolicy.cacheFirst,
    ttl: const Duration(minutes: 5),
  );
  print('second => ${r2.valueOrNull}   (network calls so far: $_calls)');

  // Pattern-match on the Result with fold().
  r2.fold(
    onSuccess: (u) => print('hello, ${u.name}'),
    onFailure: (err, _) => print('oops: $err'),
  );

  await cache.dispose();
}
