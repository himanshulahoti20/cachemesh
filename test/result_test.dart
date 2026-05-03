import 'package:cachemesh/cachemesh.dart';
import 'package:test/test.dart';

void main() {
  group('Result', () {
    test('Success exposes value and is recognized', () {
      const r = Success<int>(42);
      expect(r.isSuccess, isTrue);
      expect(r.isFailure, isFalse);
      expect(r.valueOrNull, 42);
      expect(r.errorOrNull, isNull);
    });

    test('Failure exposes error and is recognized', () {
      final r = Failure<int>('boom');
      expect(r.isSuccess, isFalse);
      expect(r.isFailure, isTrue);
      expect(r.valueOrNull, isNull);
      expect(r.errorOrNull, 'boom');
    });

    test('fold dispatches to the right branch', () {
      const ok = Success<int>(7);
      final bad = Failure<int>('nope');
      expect(ok.fold(onSuccess: (v) => 'v=$v', onFailure: (_, __) => 'err'),
          'v=7');
      expect(bad.fold(onSuccess: (v) => 'v=$v', onFailure: (e, _) => 'err=$e'),
          'err=nope');
    });

    test('map transforms success and passes failure through', () {
      const ok = Success<int>(2);
      final bad = Failure<int>('x');
      expect(ok.map((v) => v * 10), const Success<int>(20));
      expect(bad.map((v) => v * 10), Failure<int>('x'));
    });

    test('equality uses value / error', () {
      expect(const Success<int>(1), const Success<int>(1));
      expect(Failure<int>('e'), Failure<int>('e'));
      expect(const Success<int>(1) == const Success<int>(2), isFalse);
    });
  });
}
