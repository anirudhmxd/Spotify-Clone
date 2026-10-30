import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythm_app/services/work_limiter.dart';

void main() {
  test(
    'limits active work, preserves queue order and releases failed slots',
    () async {
      final limiter = WorkLimiter(2);
      final gates = List.generate(4, (_) => Completer<void>());
      final started = <int>[];
      final futures = List.generate(
        4,
        (i) => limiter.run(() async {
          started.add(i);
          await gates[i].future;
          if (i == 0) throw StateError('failed');
          return i;
        }),
      );
      final failed = expectLater(futures[0], throwsStateError);
      expect(started, [0, 1]);
      gates[0].complete();
      await failed;
      await Future<void>.delayed(Duration.zero);
      expect(started, [0, 1, 2]);
      gates[1].complete();
      await futures[1];
      await Future<void>.delayed(Duration.zero);
      expect(started, [0, 1, 2, 3]);
      gates[2].complete();
      gates[3].complete();
      expect(await Future.wait(futures.skip(1)), [1, 2, 3]);
      expect(await limiter.run(() async => 5), 5);
    },
  );
}
