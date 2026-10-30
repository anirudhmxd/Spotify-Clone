import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythm_app/music_controller.dart';
import 'package:rhythm_app/models/experience.dart';
import 'fakes.dart';

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeRepository repo;
  late FakeAudio audio;
  late MusicController c;
  setUp(() {
    repo = FakeRepository();
    audio = FakeAudio()..duration = const Duration(minutes: 6);
    c = MusicController(repo, audio);
    c.settings = c.settings.copyWith(autoplay: false);
  });
  tearDown(() => c.dispose());

  test(
    'missed native completion stops the silent tail and bounds the UI',
    () async {
      await c.playTracks([song('seed0000001')], 0);
      expect(audio.clipEnd, const Duration(seconds: 181));
      audio.tick(const Duration(seconds: 200));
      await settle();
      expect(audio.playing, isFalse);
      expect(c.playbackPosition.value, const Duration(minutes: 3));
      await c.togglePlay();
      expect(audio.position, Duration.zero);
      expect(audio.playing, isTrue);
    },
  );

  test(
    'duration guard and duplicate native completion advance exactly once',
    () async {
      await c.playTracks([
        song('seed0000001'),
        song('seed0000002'),
        song('seed0000003'),
      ], 0);
      audio.tick(const Duration(seconds: 181));
      audio.completed.add(null);
      audio.completed.add(null);
      await settle();
      expect(c.current!.id, 'seed0000002');
      expect(audio.files.length, 2);
      expect(audio.playing, isTrue);
      expect(c.playbackPosition.value, Duration.zero);
    },
  );

  test(
    'stops before waiting for recommendations and preserves a newer selection',
    () async {
      c.settings = c.settings.copyWith(autoplay: true);
      final pending = Completer<void>();
      // Use a typed recommendation gate without delaying normal playback.
      repo.onRecommend = (_) async {
        await pending.future;
        return [song('related0001')];
      };
      await c.playTracks([song('seed0000001')], 0);
      audio.tick(const Duration(seconds: 181));
      await settle();
      expect(audio.playing, isFalse);
      await c.playTracks([song('newtrack001')], 0);
      pending.complete();
      await settle();
      expect(c.current!.id, 'newtrack001');
      expect(audio.playing, isTrue);
    },
  );

  test('sleep after track takes precedence over repeat', () async {
    await c.playTracks([song('seed0000001'), song('seed0000002')], 0);
    await c.setRepeat(RepeatMode.one);
    c.setSleepTimer(null, afterTrack: true);
    audio.tick(const Duration(seconds: 181));
    await settle();
    expect(audio.playing, isFalse);
    expect(c.current!.id, 'seed0000001');
    expect(c.sleepAfterTrack, isFalse);
  });

  test('repeat restarts at zero and can complete again', () async {
    await c.playTracks([song('seed0000001')], 0);
    await c.setRepeat(RepeatMode.one);
    for (var i = 0; i < 2; i++) {
      audio.tick(const Duration(seconds: 181));
      await settle();
      expect(audio.position, Duration.zero);
      expect(audio.playing, isTrue);
      expect(c.current!.id, 'seed0000001');
    }
  });

  test(
    'seek is bounded and paused/buffering playback does not trigger the guard',
    () async {
      await c.playTracks([song('seed0000001')], 0);
      await c.seek(const Duration(minutes: 20));
      expect(audio.position, const Duration(minutes: 3));
      await c.seek(const Duration(seconds: -5));
      expect(audio.position, Duration.zero);
      audio.loading = true;
      audio.tick(const Duration(seconds: 200));
      expect(audio.playing, isTrue);
      audio.loading = false;
      await c.pause();
      audio.tick(const Duration(seconds: 200));
      await settle();
      expect(c.current!.id, 'seed0000001');
      expect(audio.playing, isFalse);
    },
  );
}
