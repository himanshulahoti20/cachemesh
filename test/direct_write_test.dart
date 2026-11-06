import 'package:cachemesh/cachemesh.dart';
import 'package:test/test.dart';

void main() {
  late Cache cache;
  setUp(() => cache = Cache());
  tearDown(() async => cache.dispose());

  test('set seeds the cache, skips fetch, and notifies watchers', () async {
    final events = <Result<int>>[];
    cache.watch<int>('n').listen(events.add);
    cache.set<int>('n', 1);
    var fetched = false;
    final r = await cache.get<int>(
      key: 'n',
      fetch: () async {
        fetched = true;
        return const Success(99);
      },
    );
    await Future<void>.delayed(Duration.zero);
    expect(r, const Success<int>(1));
    expect(fetched, isFalse);
    expect(events, [const Success<int>(1)]);
  });

  test('set clears a cached failure', () async {
    await cache.get<int>(
      key: 'n',
      fetch: () async => Failure<int>(StateError('x')),
      cacheFailures: true,
    );
    expect(cache.hasCachedFailure('n'), isTrue);
    cache.set<int>('n', 1);
    expect(cache.hasCachedFailure('n'), isFalse);
  });

  test('update transforms in place, keeping ttl and scope', () {
    cache.setActiveUser('u');
    cache.set<int>(
      'n',
      1,
      ttl: const Duration(minutes: 1),
      scope: CacheScope.session,
    );
    expect(cache.update<int>('n', (v) => v + 1), 2);
    expect(cache.peek<int>('n'), 2);
    expect(cache.inspect<int>('n').ttl, const Duration(minutes: 1));
    expect(cache.scopeOf('n'), CacheScope.session);
  });

  test('update on a missing key is a no-op', () {
    expect(cache.update<int>('nope', (v) => v + 1), isNull);
    expect(cache.contains('nope'), isFalse);
  });

  test('invalidateWhere drops matching keys only', () {
    cache
      ..set<int>('user:1', 1)
      ..set<int>('user:2', 2)
      ..set<int>('post:1', 3);
    expect(cache.invalidateWhere((k) => k.startsWith('user:')), 2);
    expect(cache.allKeys, ['post:1']);
  });
}
