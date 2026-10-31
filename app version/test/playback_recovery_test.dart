import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhythm_app/music_controller.dart';

import 'fakes.dart';

Future<void> settle() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late FakeRepository repo;
  late FakeAudio audio;
  late MusicController controller;

  setUp(() {
    repo = FakeRepository();
    audio = FakeAudio();
    controller = MusicController(repo, audio);
    controller.settings = controller.settings.copyWith(autoplay: false);
  });
  tearDown(() => controller.dispose());

  test('runtime failure refreshes audio and resumes the same position', () async {
    await controller.playTracks([song('seed0000001')], 0);
    audio.tick(const Duration(seconds: 42));
    audio.states.addError(StateError('Connection lost'));
    await settle();

    expect(repo.refreshed, ['seed0000001']);
    expect(audio.files, hasLength(2));
    expect(audio.position, const Duration(seconds: 42));
    expect(audio.playing, isTrue);
    expect(controller.queueIndex, 0);
    expect(controller.resolvingAudio, isFalse);
  });

  test('repeated failures use a download and stop after two retries', () async {
    await controller.playTracks([song('seed0000001')], 0);
    for (var i = 0; i < 3; i++) {
      audio.states.addError(StateError('Stream failed'));
      await settle();
    }
    expect(repo.resolutions, [false, false, true]);
    expect(audio.playing, isFalse);
    expect(controller.notice, contains('Playback was interrupted'));
  });

  test('failed refresh falls back to a complete file', () async {
    await controller.playTracks([song('seed0000001')], 0);
    repo.onResolve = (_, download) async {
      if (!download) throw StateError('Stream unavailable');
      return 'file:///tmp/recovered.m4a';
    };
    audio.states.addError(StateError('Connection lost'));
    await settle();
    expect(repo.resolutions, [false, false, true]);
    expect(audio.files.last, '/tmp/recovered.m4a');
    expect(audio.playing, isTrue);
  });

  test('pause cancels an outstanding recovery', () async {
    await controller.playTracks([song('seed0000001')], 0);
    final pending = Completer<String>();
    repo.onResolve = (_, _) => pending.future;
    audio.states.addError(StateError('Connection lost'));
    await settle();
    await controller.pause();
    pending.complete('file:///tmp/stale.m4a');
    await settle();
    expect(audio.files, hasLength(1));
    expect(audio.playing, isFalse);
  });

  test('a newer selection cancels an outstanding recovery', () async {
    await controller.playTracks([song('seed0000001')], 0);
    final pending = Completer<String>();
    repo.onResolve = (track, _) => track.id == 'seed0000001'
        ? pending.future
        : Future.value('file:///tmp/new.m4a');
    audio.states.addError(StateError('Connection lost'));
    await settle();
    await controller.playTracks([song('seed0000002')], 0);
    pending.complete('file:///tmp/stale.m4a');
    await settle();
    expect(controller.current!.id, 'seed0000002');
    expect(audio.files.last, '/tmp/new.m4a');
    expect(audio.playing, isTrue);
  });

  testWidgets('prolonged buffering recovers without a position event', (tester) async {
    var clock = DateTime(2026);
    final stalledAudio = FakeAudio();
    final recovery = MusicController(repo, stalledAudio, now: () => clock);
    try {
      await recovery.playTracks([song('seed0000001')], 0);
      stalledAudio.tick(const Duration(seconds: 42));
      await tester.pump(const Duration(seconds: 2));
      stalledAudio.loading = true;
      clock = clock.add(const Duration(seconds: 18));
      await tester.pump(const Duration(seconds: 18));
      expect(repo.refreshed, ['seed0000001']);
      expect(stalledAudio.position, const Duration(seconds: 42));
      expect(stalledAudio.playing, isTrue);
    } finally {
      recovery.dispose();
    }
  });

  testWidgets('system pause does not restart playback', (tester) async {
    var clock = DateTime(2026);
    final pausedAudio = FakeAudio();
    final recovery = MusicController(repo, pausedAudio, now: () => clock);
    try {
      await recovery.playTracks([song('seed0000001')], 0);
      await pausedAudio.pause();
      clock = clock.add(const Duration(seconds: 40));
      await tester.pump(const Duration(seconds: 40));
      expect(repo.refreshed, isEmpty);
      expect(pausedAudio.playing, isFalse);
    } finally {
      recovery.dispose();
    }
  });
}
