import 'package:cachemesh/cachemesh.dart';
import 'package:test/test.dart';

void main() {
  late Cache cache;

  setUp(() => cache = Cache());
  tearDown(() async => cache.dispose());

  Future<void> seed(String key, Object value) => cache.refresh<Object>(
        key: key,
        fetch: () async => Success(value),
      );

  group('combineLatest', () {
    test('empty keys: emits an immediate Success with combine([])', () async {
      final stream = cache.combineLatest<String>([], (_) => 'ok');
      expect(await stream.first, const Success<String>('ok'));
    });

    test('emits the initial combined value when all keys are present',
        () async {
      await seed('a', 1);
      await seed('b', 2);

      final stream = cache.combineLatest<int>(
        ['a', 'b'],
        (values) => (values[0] as int) + (values[1] as int),
      );
      final first = await stream.first;
      expect(first, const Success<int>(3));
    });

    test('does not emit until every key has a value', () async {
      await seed('a', 1);
      final stream = cache.combineLatest<int>(
        ['a', 'b'],
        (values) => (values[0] as int) + (values[1] as int),
      );

      final events = <Result<int>>[];
      final sub = stream.listen(events.add);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty, reason: 'b is missing');

      await seed('b', 10);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(events.single, const Success<int>(11));
      await sub.cancel();
    });

    test('re-emits when any underlying key updates', () async {
      await seed('a', 1);
      await seed('b', 2);
      final stream = cache.combineLatest<int>(
        ['a', 'b'],
        (values) => (values[0] as int) + (values[1] as int),
      );
      final events = <Result<int>>[];
      final sub = stream.listen(events.add);
      await Future<void>.delayed(Duration.zero);

      await seed('a', 5);
      await Future<void>.delayed(Duration.zero);
      await seed('b', 10);
      await Future<void>.delayed(Duration.zero);

      expect(events, [
        const Success<int>(3),
        const Success<int>(7),
        const Success<int>(15),
      ]);
      await sub.cancel();
    });

    test('canceling the subscription unsubscribes from underlying watches',
        () async {
      await seed('a', 1);
      await seed('b', 2);
      final stream = cache.combineLatest<int>(
        ['a', 'b'],
        (values) => (values[0] as int) + (values[1] as int),
      );
      final sub = stream.listen((_) {});
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      // No further emissions expected after cancel; just ensure no throw.
      await seed('a', 9);
      await Future<void>.delayed(Duration.zero);
    });

    test('exception inside combine() is wrapped as a Failure', () async {
      await seed('a', 1);
      await seed('b', 2);
      final stream = cache.combineLatest<int>(
        ['a', 'b'],
        (_) => throw StateError('boom'),
      );
      final first = await stream.first;
      expect(first.isFailure, isTrue);
      expect(first.errorOrNull, isA<StateError>());
    });
  });

  group('peekCombined', () {
    test('returns null when any key is missing', () async {
      await seed('a', 1);
      expect(cache.peekCombined<int>(['a', 'b'], (v) => 0), isNull);
    });

    test('returns combined Success when all present', () async {
      await seed('a', 1);
      await seed('b', 2);
      expect(
        cache.peekCombined<int>(
          ['a', 'b'],
          (v) => (v[0] as int) + (v[1] as int),
        ),
        const Success<int>(3),
      );
    });

    test('captures combine() exceptions as Failure', () async {
      await seed('a', 1);
      expect(
        cache
            .peekCombined<int>(['a'], (_) => throw StateError('x'))
            .runtimeType
            .toString(),
        contains('Failure'),
      );
    });
  });
}
