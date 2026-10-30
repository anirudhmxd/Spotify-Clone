import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythm_app/models/music.dart';
import 'package:rhythm_app/music_controller.dart';
import 'package:rhythm_app/services/media_controls.dart';
import 'fakes.dart';

void main() {
  late FakeRepository repo;
  late FakeAudio audio;
  late MusicController c;
  late DeviceMediaHandler handler;
  setUp(() {
    repo = FakeRepository();
    audio = FakeAudio();
    c = MusicController(repo, audio);
    handler = DeviceMediaHandler(c);
  });
  tearDown(() => c.dispose());

  test('publishes artwork, metadata and compact playback buttons', () async {
    const track = Track(
      id: 'song0000001',
      title: 'Carousel',
      artist: 'Aries',
      album: 'Single',
      artwork: 'https://example.com/art.jpg',
      stream: '',
      durationMs: 180000,
    );
    await c.playTracks([track, song('song0000002')], 0);
    expect(handler.mediaItem.value!.title, 'Carousel');
    expect(handler.mediaItem.value!.artist, 'Aries');
    expect(handler.mediaItem.value!.artUri.toString(), track.artwork);
    expect(handler.mediaItem.value!.duration, const Duration(minutes: 3));
    expect(handler.queue.value.map((item) => item.id), [
      'song0000001',
      'song0000002',
    ]);
    expect(
      handler.playbackState.value.controls.map((control) => control.action),
      [
        MediaAction.skipToPrevious,
        MediaAction.pause,
        MediaAction.skipToNext,
        MediaAction.stop,
      ],
    );
    expect(handler.playbackState.value.androidCompactActionIndices, [0, 1, 2]);
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.ready,
    );
  });

  test(
    'notification pause, resume, next and previous control the same player',
    () async {
      await c.playTracks([song('song0000001'), song('song0000002')], 0);
      await handler.pause();
      expect(audio.playing, isFalse);
      expect(handler.playbackState.value.controls[1].action, MediaAction.play);
      await handler.play();
      await handler.play(); // System play is idempotent.
      expect(audio.playing, isTrue);
      await handler.skipToNext();
      expect(c.current!.id, 'song0000002');
      expect(handler.mediaItem.value!.id, 'song0000002');
      expect(handler.playbackState.value.queueIndex, 1);
      await handler.skipToPrevious();
      expect(c.current!.id, 'song0000001');
    },
  );

  test(
    'notification seeks publish the new position and stay in song bounds',
    () async {
      await c.playTracks([song('song0000001')], 0);
      await handler.seek(const Duration(seconds: 45));
      expect(audio.position, const Duration(seconds: 45));
      expect(
        handler.playbackState.value.updatePosition,
        const Duration(seconds: 45),
      );
      await handler.seek(const Duration(hours: 1));
      expect(audio.position, const Duration(minutes: 3));
      await handler.seek(const Duration(seconds: -5));
      expect(audio.position, Duration.zero);
    },
  );

  test(
    'loading keeps the media service active and repeated play does not cancel it',
    () async {
      final pending = Completer<String>();
      repo.onResolve = (_, _) => pending.future;
      final playing = c.playTracks([song('song0000001')], 0);
      await Future<void>.delayed(Duration.zero);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.loading,
      );
      expect(handler.playbackState.value.playing, isTrue);
      expect(handler.playbackState.value.controls[1].action, MediaAction.pause);
      expect(handler.playbackState.value.updatePosition, Duration.zero);
      expect(handler.playbackState.value.systemActions, isEmpty);
      await handler.play();
      expect(c.resolvingAudio, isTrue);
      await handler.seek(const Duration(seconds: 10));
      expect(audio.position, Duration.zero);
      pending.complete('file:///tmp/song.m4a');
      await playing;
      expect(audio.playing, isTrue);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.ready,
      );
    },
  );

  test(
    'notification pause cancels a pending song without starting it later',
    () async {
      final pending = Completer<String>();
      repo.onResolve = (_, _) => pending.future;
      final playing = c.playTracks([song('song0000001')], 0);
      await Future<void>.delayed(Duration.zero);
      await handler.pause();
      pending.complete('file:///tmp/song.m4a');
      await playing;
      expect(audio.playing, isFalse);
      expect(audio.files, isEmpty);
      expect(handler.playbackState.value.controls[1].action, MediaAction.play);
    },
  );

  test('removing the activity task leaves active playback running', () async {
    await c.playTracks([song('song0000001')], 0);
    await handler.onTaskRemoved();
    expect(audio.playing, isTrue);
    expect(handler.playbackState.value.playing, isTrue);
  });

  test(
    'notification dismissal stops playback until explicitly resumed',
    () async {
      await c.playTracks([song('song0000001')], 0);
      await handler.onNotificationDeleted();
      expect(audio.playing, isFalse);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.idle,
      );
      c.navigate(MusicPage.library);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.idle,
      );
      await handler.play();
      expect(audio.playing, isTrue);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.ready,
      );
    },
  );

  test('failed loading clears the active play intent', () async {
    repo.onResolve = (_, _) async => throw StateError('No connection');
    await c.playTracks([song('song0000001')], 0);
    expect(handler.playbackState.value.playing, isFalse);
    expect(handler.playbackState.value.controls[1].action, MediaAction.play);
  });
}
