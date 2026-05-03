import 'dart:async';

import 'package:cachemesh/cachemesh.dart';
import 'package:test/test.dart';

class _RecordingLogger extends CacheLogger {
  final List<String> events = [];

  @override
  void onHit(String key) => events.add('hit:$key');
  @override
  void onMiss(String key) => events.add('miss:$key');
  @override
  void onWrite(String key, {Duration? ttl}) => events.add('write:$key');
  @override
  void onRefresh(String key, RefreshSource source) =>
      events.add('refresh:$key:${source.name}');
  @override
  void onInvalidate(String key) => events.add('invalidate:$key');
  @override
  void onClear() => events.add('clear');
  @override
  void onError(String key, Object error, StackTrace? stackTrace) =>
      events.add('error:$key:$error');
}

class _Clock {
  DateTime now = DateTime(2026, 1, 1);
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

void main() {
  late _RecordingLogger log;
  late Cache cache;
  late _Clock clock;

  setUp(() {
    log = _RecordingLogger();
    clock = _Clock();
    cache = Cache(logger: log, clock: clock.call);
  });

  tearDown(() async => cache.dispose());

  test('cacheFirst: miss then hit', () async {
    await cache.get<int>(
      key: 'k',
      fetch: () async => const Success(1),
      policy: CachePolicy.cacheFirst,
    );
    await cache.get<int>(
      key: 'k',
      fetch: () async => const Success(2),
      policy: CachePolicy.cacheFirst,
    );
    expect(log.events, [
      'miss:k',
      'refresh:k:cacheMiss',
      'write:k',
      'hit:k',
    ]);
  });

  test('networkFirst: refresh + write on success', () async {
    await cache.get<int>(
      key: 'k',
      fetch: () async => const Success(1),
      policy: CachePolicy.networkFirst,
    );
    expect(log.events, ['refresh:k:policy', 'write:k']);
  });

  test('staleWhileRevalidate: hit + background refresh', () async {
    await cache.get<int>(
      key: 'k',
      fetch: () async => const Success(1),
      policy: CachePolicy.cacheFirst,
    );
    log.events.clear();

    await cache.get<int>(
      key: 'k',
      fetch: () async => const Success(2),
      policy: CachePolicy.staleWhileRevalidate,
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(log.events, [
      'hit:k',
      'refresh:k:background',
      'write:k',
    ]);
  });

  test('failure surfaces an error event but no write', () async {
    await cache.get<int>(
      key: 'k',
      fetch: () async => Failure<int>('boom'),
      policy: CachePolicy.networkFirst,
    );
    expect(log.events, ['refresh:k:policy', 'error:k:boom']);
  });

  test('invalidate and clear emit events', () async {
    cache.invalidate('k');
    cache.clear();
    expect(log.events, ['invalidate:k', 'clear']);
  });

  test('refresh and prefetch carry their own RefreshSource', () async {
    await cache.refresh<int>(key: 'k', fetch: () async => const Success(1));
    await cache.prefetch<int>(key: 'k', fetch: () async => const Success(2));
    expect(log.events, [
      'refresh:k:refresh',
      'write:k',
      'refresh:k:prefetch',
      'write:k',
    ]);
  });
}
