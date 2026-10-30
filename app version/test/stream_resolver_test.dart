import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythm_app/services/stream_resolver.dart';

void main() {
  test(
    'native candidate wins without waiting for a stalled direct extractor',
    () async {
      final slow = Completer<String?>();
      final resolver = StreamResolver(
        direct: (_) => slow.future,
        native: (_) async => 'https://audio.example/native',
        nativeDelay: Duration.zero,
      );
      expect(await resolver.resolve('song'), 'https://audio.example/native');
      slow.complete('https://audio.example/late');
      await Future<void>.delayed(Duration.zero);
      expect(await resolver.resolve('song'), 'https://audio.example/native');
      resolver.dispose();
    },
  );
  test(
    'failed direct candidate cannot end an already running native attempt',
    () async {
      final direct = Completer<String?>(), native = Completer<String?>();
      final resolver = StreamResolver(
        direct: (_) => direct.future,
        native: (_) => native.future,
        nativeDelay: Duration.zero,
      );
      final result = resolver.resolve('song');
      await Future<void>.delayed(Duration.zero);
      direct.completeError(StateError('Unavailable'));
      await Future<void>.delayed(Duration.zero);
      native.complete('https://audio.example/native');
      expect(await result, 'https://audio.example/native');
      resolver.dispose();
    },
  );
  test('fast direct extraction avoids starting the native engine', () async {
    var nativeCalls = 0;
    final resolver = StreamResolver(
      direct: (_) async => 'https://audio.example/direct',
      native: (_) async {
        nativeCalls++;
        return 'https://audio.example/native';
      },
    );
    expect(await resolver.resolve('song'), 'https://audio.example/direct');
    expect(nativeCalls, 0);
    resolver.dispose();
  });
  test(
    'preparation and play share extraction; failures never poison other songs',
    () async {
      var calls = 0;
      final pending = Completer<String?>();
      final resolver = StreamResolver(
        direct: (id) async {
          calls++;
          if (id == 'broken') throw StateError('Unavailable');
          return pending.future;
        },
      );
      final first = resolver.resolve('song'), second = resolver.resolve('song');
      pending.complete('https://audio.example/cached');
      expect(await first, await second);
      expect(calls, 1);
      await expectLater(resolver.resolve('broken'), throwsStateError);
      expect(await resolver.resolve('song'), 'https://audio.example/cached');
      await expectLater(resolver.resolve('broken'), throwsStateError);
      expect(calls, 3);
      resolver.dispose();
    },
  );
  test(
    'a rejected URL refreshes through native extraction rather than cached direct URL',
    () async {
      var directCalls = 0, nativeCalls = 0;
      final resolver = StreamResolver(
        direct: (_) async {
          directCalls++;
          return 'https://audio.example/direct';
        },
        native: (_) async {
          nativeCalls++;
          return 'https://audio.example/native';
        },
      );
      await resolver.resolve('song');
      expect(
        await resolver.resolve('song', refresh: true),
        'https://audio.example/native',
      );
      expect(await resolver.resolve('song'), 'https://audio.example/native');
      expect(directCalls, 1);
      expect(nativeCalls, 1);
      resolver.dispose();
    },
  );
  test('signed URLs are refreshed before expiration', () async {
    var time = DateTime.utc(2026), calls = 0;
    final expiration =
        time.add(const Duration(minutes: 2)).millisecondsSinceEpoch ~/ 1000;
    final resolver = StreamResolver(
      now: () => time,
      direct: (_) async {
        calls++;
        return 'https://audio.example/$calls?expire=$expiration';
      },
    );
    await resolver.resolve('song');
    time = time.add(const Duration(seconds: 61));
    await resolver.resolve('song');
    expect(calls, 2);
    resolver.dispose();
  });
}
