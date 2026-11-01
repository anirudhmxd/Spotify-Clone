import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythm/music_controller.dart';
import 'package:rhythm/models/experience.dart';
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
    'zero-position Windows completions keep the clicked queue song',
    () async {
      final tracks = [
        song('seed0000001'),
        song('seed0000002'),
        song('seed0000003'),
        song('seed0000004'),
      ];
      await c.playTracks(tracks, 1);
      // WinRT can report position == duration == zero before metadata arrives.
      audio.duration = Duration.zero;
      for (var i = 0; i < tracks.length; i++) {
        audio.completed.add(null);
        await settle();
      }
      expect(c.current!.id, tracks[1].id);
      expect(c.queueIndex, 1);
      expect(audio.files, ['/tmp/${tracks[1].id}.m4a']);
      expect(audio.playing, isTrue);

      // A real native completion still advances once, even without a final tick.
      audio.duration = const Duration(minutes: 3);
      audio.position = audio.duration;
      audio.completed.add(null);
      audio.completed.add(null);
      await settle();
      expect(c.current!.id, tracks[2].id);
      expect(c.queueIndex, 2);
      expect(audio.files, hasLength(2));
      expect(audio.playing, isTrue);
    },
  );

  test('startup completion does not skip through radio suggestions', () async {
    c.settings = c.settings.copyWith(autoplay: true);
    repo.recommendations = [song('related0001'), song('related0002')];
    await c.playRadio(song('seed0000001'));
    await settle();
    for (var i = 0; i < 3; i++) {
      audio.completed.add(null);
      await settle();
    }
    expect(c.current!.id, 'seed0000001');
    expect(c.queue.map((track) => track.id), [
      'seed0000001',
      'related0001',
      'related0002',
    ]);
    expect(c.queueIndex, 0);
    expect(audio.files, ['/tmp/seed0000001.m4a']);
    expect(audio.playing, isTrue);
  });

  test(
    'nonzero premature completion recovers the seed and keeps suggestions',
    () async {
      c.settings = c.settings.copyWith(autoplay: true);
      repo.recommendations = [song('related0001'), song('related0002')];
      await c.playRadio(song('seed0000001'));
      await settle();
      // A truncated native timeline can claim EOF after a fraction of a second.
      // A positive position alone must not authorize advancing the queue.
      audio.position = const Duration(milliseconds: 250);
      audio.duration = audio.position;
      audio.completed.add(null);
      await settle();
      expect(c.current!.id, 'seed0000001');
      expect(c.queueIndex, 0);
      expect(c.queue.map((track) => track.id), [
        'seed0000001',
        'related0001',
        'related0002',
      ]);
      expect(repo.refreshed, ['seed0000001']);
      expect(audio.files, ['/tmp/seed0000001.m4a', '/tmp/seed0000001.m4a']);
      expect(audio.position, const Duration(milliseconds: 250));
      expect(audio.playing, isTrue);

      // The recovered song can finish normally and start exactly one suggestion.
      audio.duration = const Duration(minutes: 3);
      audio.position = const Duration(milliseconds: 179500);
      audio.completed.add(null);
      audio.completed.add(null);
      await settle();
      expect(c.current!.id, 'related0001');
      expect(audio.files, hasLength(3));
    },
  );

  test(
    'repeated premature ends stop on the clicked queue item after bounded retries',
    () async {
      await c.playTracks([
        song('seed0000001'),
        song('seed0000002'),
        song('seed0000003'),
      ], 1);
      for (var i = 0; i < 5; i++) {
        audio.position = const Duration(seconds: 5);
        audio.duration = audio.position;
        audio.completed.add(null);
        await settle();
      }
      expect(c.current!.id, 'seed0000002');
      expect(c.queueIndex, 1);
      expect(repo.resolutions, [false, false, true]);
      expect(audio.files, List.filled(3, '/tmp/seed0000002.m4a'));
      expect(audio.playing, isFalse);
      expect(c.notice, contains('Playback was interrupted'));
      expect(c.queue, hasLength(3));
      // An explicit Next click is still permitted after the failed selection.
      await c.next();
      expect(c.current!.id, 'seed0000003');
      expect(audio.playing, isTrue);
    },
  );

  test('a late completion after pause does not advance the queue', () async {
    await c.playTracks([song('seed0000001'), song('seed0000002')], 0);
    audio.position = const Duration(minutes: 3);
    await c.pause();
    audio.completed.add(null);
    await settle();
    expect(c.current!.id, 'seed0000001');
    expect(audio.files, hasLength(1));
    expect(audio.playing, isFalse);
  });

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
