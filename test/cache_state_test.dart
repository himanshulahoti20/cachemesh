import 'package:cachemesh/cachemesh.dart';
import 'package:test/test.dart';

class _Clock {
  DateTime now = DateTime(2026, 1, 1);
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

void main() {
  late _Clock clock;
  late Cache cache;

  setUp(() {
    clock = _Clock();
    cache = Cache(clock: clock.call);
  });

  tearDown(() async => cache.dispose());

  test('inspect on missing key', () {
    final state = cache.inspect<int>('nope');
    expect(state.isMissing, isTrue);
    expect(state.isPresent, isFalse);
    expect(state.isFresh, isFalse);
    expect(state.isStale, isFalse);
    expect(state.value, isNull);
    expect(state.age, isNull);
    expect(state.timeToExpiry, isNull);
    expect(state.expiresAt, isNull);
  });

  test('inspect on fresh entry', () async {
    await cache.get<int>(
      key: 'k',
      fetch: () async => const Success(7),
      policy: CachePolicy.cacheFirst,
      ttl: const Duration(minutes: 10),
    );
    clock.advance(const Duration(minutes: 3));

    final state = cache.inspect<int>('k');
    expect(state.isPresent, isTrue);
    expect(state.isFresh, isTrue);
    expect(state.isStale, isFalse);
    expect(state.value, 7);
    expect(state.age, const Duration(minutes: 3));
    expect(state.timeToExpiry, const Duration(minutes: 7));
  });

  test('inspect on expired entry => stale', () async {
    await cache.get<int>(
      key: 'k',
      fetch: () async => const Success(7),
      policy: CachePolicy.cacheFirst,
      ttl: const Duration(seconds: 5),
    );
    clock.advance(const Duration(seconds: 10));

    final state = cache.inspect<int>('k');
    expect(state.isPresent, isTrue);
    expect(state.isFresh, isFalse);
    expect(state.isStale, isTrue);
    expect(state.value, 7);
    expect(state.timeToExpiry, const Duration(seconds: -5));
  });

  test('inspect with no ttl => always fresh', () async {
    await cache.get<int>(
      key: 'k',
      fetch: () async => const Success(7),
      policy: CachePolicy.cacheFirst,
    );
    clock.advance(const Duration(days: 365));

    final state = cache.inspect<int>('k');
    expect(state.isFresh, isTrue);
    expect(state.expiresAt, isNull);
    expect(state.timeToExpiry, isNull);
  });

  test('toString summarises the snapshot', () async {
    await cache.get<int>(
      key: 'k',
      fetch: () async => const Success(1),
      policy: CachePolicy.cacheFirst,
      ttl: const Duration(seconds: 5),
    );
    clock.advance(const Duration(seconds: 1));
    expect(cache.inspect<int>('k').toString(), contains('fresh'));
    expect(cache.inspect<int>('missing').toString(), contains('missing'));
  });
}
