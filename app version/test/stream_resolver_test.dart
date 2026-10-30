import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythm_app/services/stream_resolver.dart';

void main() {
  test('preparation and playback share extraction and cached URLs', () async {
    final pending = Completer<String?>();
    var calls = 0;
    final resolver = StreamResolver(
      direct: (_) {
        calls++;
        return pending.future;
      },
    );
    final first = resolver.resolve('song'), second = resolver.resolve('song');
    pending.complete('https://audio.example/song');
    expect(await first, await second);
    expect(await resolver.resolve('song'), 'https://audio.example/song');
    expect(calls, 1);
    resolver.dispose();
  });
  test('failure remains retryable and does not disable other songs', () async {
    var fail = true;
    final resolver = StreamResolver(
      direct: (id) async {
        if (fail && id == 'bad') throw StateError('Unavailable');
        return 'https://audio.example/$id';
      },
    );
    await expectLater(resolver.resolve('bad'), throwsStateError);
    expect(await resolver.resolve('good'), endsWith('/good'));
    fail = false;
    expect(await resolver.resolve('bad'), endsWith('/bad'));
    resolver.dispose();
  });
  test('refresh discards the old URL', () async {
    var calls = 0;
    final resolver = StreamResolver(
      direct: (_) async => 'https://audio.example/${++calls}',
    );
    expect(await resolver.resolve('song'), endsWith('/1'));
    expect(await resolver.resolve('song', refresh: true), endsWith('/2'));
    resolver.dispose();
  });
  test('signed URLs expire before their server expiration', () async {
    var time = DateTime.utc(2026), calls = 0;
    final expiration =
        time.add(const Duration(minutes: 2)).millisecondsSinceEpoch ~/ 1000;
    final resolver = StreamResolver(
      now: () => time,
      direct: (_) async =>
          'https://audio.example/${++calls}?expire=$expiration',
    );
    await resolver.resolve('song');
    time = time.add(const Duration(seconds: 61));
    await resolver.resolve('song');
    expect(calls, 2);
    resolver.dispose();
  });
  test('timeout and closed resolver report errors', () async {
    final pending = Completer<String?>();
    final resolver = StreamResolver(
      direct: (_) => pending.future,
      timeout: const Duration(milliseconds: 20),
    );
    await expectLater(
      resolver.resolve('song'),
      throwsA(isA<TimeoutException>()),
    );
    pending.complete(null);
    resolver.dispose();
    await expectLater(resolver.resolve('song'), throwsStateError);
  });
}
