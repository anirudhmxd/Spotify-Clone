import 'dart:async';
import 'dart:math';
import 'package:audio_service/audio_service.dart';
import 'package:rhythm_app/services/media_controls.dart';
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythm_app/main.dart';
import 'package:rhythm_app/models/experience.dart';
import 'package:rhythm_app/models/music.dart';
import 'package:rhythm_app/music_controller.dart';
import 'package:rhythm_app/widgets/playback_panels.dart';
import 'package:rhythm_app/widgets/playlist_editor.dart';
import 'music_test.dart' show FakeAudio, FakeRepository, a, b, tick;

void position(FakeAudio audio, int seconds) {
  audio.position = Duration(seconds: seconds);
  audio.positionEvents.add(audio.position);
}

void main() {
  test(
    'seeks, pauses, buffering and private sessions do not inflate listening',
    () async {
      final repo = FakeRepository();
      final audio = FakeAudio();
      final c = MusicController(repo, audio);
      await c.playTracks([a], 0);
      position(audio, 1);
      position(audio, 2);
      await c.seek(const Duration(seconds: 80));
      position(audio, 80);
      position(audio, 81);
      audio.loading = true;
      position(audio, 82);
      audio.loading = false;
      await c.pause();
      position(audio, 83);
      await c.updateSettings(c.settings.copyWith(privateSession: true));
      await c.togglePlay();
      position(audio, 84);
      position(audio, 85);
      await c.pause();
      expect(repo.listening.fold(0, (n, e) => n + e.milliseconds), 3000);
      expect(repo.scores, 0);
      expect(repo.listening.fold(0, (n, e) => n + e.plays), 1);
      c.dispose();
    },
  );
  test(
    'speed changes count elapsed listening time instead of media length',
    () async {
      final repo = FakeRepository();
      final audio = FakeAudio();
      final c = MusicController(repo, audio);
      await c.updateSettings(c.settings.copyWith(speed: 2));
      await c.playTracks([a], 0);
      position(audio, 2);
      position(audio, 4);
      await c.pause();
      expect(repo.listening.single.milliseconds, 2000);
      expect(audio.speed, 2);
      c.dispose();
    },
  );
  test(
    'pausing an unresolved song prevents autoplay and resume resolves it again',
    () async {
      final pending = Completer<String>();
      final repo = FakeRepository()..onResolve = (_) => pending.future;
      final audio = FakeAudio();
      final c = MusicController(repo, audio);
      final play = c.playTracks([a], 0);
      await tick();
      await c.pause();
      pending.complete('https://example.com/a');
      await play;
      expect(audio.playing, false);
      expect(audio.loaded, isNull);
      await c.togglePlay();
      expect(audio.playing, true);
      expect(audio.loaded, 'https://example.com/a');
      c.dispose();
    },
  );
  test(
    'repeat off stops, repeat all restarts and autoplay can be disabled',
    () async {
      final audio = FakeAudio();
      final c = MusicController(FakeRepository(), audio);
      await c.updateSettings(c.settings.copyWith(autoplay: false));
      await c.playTracks([a], 0);
      await c.next(recommend: true);
      expect(audio.playing, false);
      expect(c.queue.length, 1);
      await c.setRepeat(RepeatMode.all);
      await c.next(recommend: true);
      expect(audio.playing, true);
      expect(c.current?.id, a.id);
      expect(c.queue.length, 1);
      c.dispose();
    },
  );
  test('shuffle, reorder and removal preserve the playing item', () async {
    final c = MusicController(FakeRepository(), FakeAudio(), random: Random(4));
    await c.playTracks([a, b], 0);
    c.addToQueue(a);
    c.toggleShuffle();
    expect(c.queue.first.id, a.id);
    expect(c.current?.id, a.id);
    c.reorderQueue(0, 2);
    expect(c.queueIndex, 2);
    expect(c.queue[c.queueIndex].id, a.id);
    c.removeQueueItem(0);
    expect(c.queueIndex, 1);
    c.removeQueueItem(1);
    expect(c.queue.length, 2);
    c.addToQueue(b, next: true);
    expect(c.queue[c.queueIndex + 1].id, b.id);
    c.clearUpcoming();
    expect(c.queue.length, c.queueIndex + 1);
    c.dispose();
  });
  test(
    'same song selected from another collection replaces the queue',
    () async {
      final c = MusicController(FakeRepository(), FakeAudio());
      await c.playTracks([a], 0);
      await c.playTracks([a, b], 0);
      expect(c.queue.length, 2);
      expect(c.audio.playing, true);
      c.dispose();
    },
  );
  test(
    'saved playlist edits do not overwrite a manually edited queue',
    () async {
      final c = MusicController(FakeRepository(), FakeAudio());
      await c.createPlaylist('List', track: a);
      final p = c.playlists.single;
      await c.playPlaylist(p);
      c.addToQueue(b);
      expect(
        await c.editPlaylist(p.copyWith(name: 'Renamed', tracks: [b])),
        true,
      );
      expect(c.activePlaylistId, isNull);
      expect(c.playlists.single.name, 'Renamed');
      expect(c.queue.map((t) => t.id), [a.id, b.id]);
      c.dispose();
    },
  );
  testWidgets('sleep timer pauses and end-of-song timer overrides repeat', (
    tester,
  ) async {
    final c = MusicController(FakeRepository(), FakeAudio());
    await c.playTracks([a], 0);
    c.setSleepTimer(const Duration(minutes: 5));
    await tester.pump(const Duration(minutes: 5));
    expect(c.audio.playing, false);
    expect(c.sleepUntil, isNull);
    await c.togglePlay();
    await c.setRepeat(RepeatMode.one);
    c.setSleepTimer(null, afterTrack: true);
    await tester.pump();
    expect(c.repeatMode, RepeatMode.off);
    (c.audio as FakeAudio).completionEvents.add(null);
    await tester.pump();
    expect(c.audio.playing, false);
    expect(c.sleepAfterTrack, false);
    c.dispose();
  });
  test('replaying a completed song starts a new listening session', () async {
    final repo = FakeRepository();
    final audio = FakeAudio();
    final c = MusicController(repo, audio);
    await c.playTracks([a], 0);
    for (var i = 1; i <= 100; i++) {
      position(audio, i);
    }
    await c.pause();
    await c.togglePlay();
    for (var i = 1; i <= 90; i++) {
      position(audio, i);
    }
    await c.pause();
    expect(repo.scores, 2);
    expect(repo.listening.fold(0, (sum, e) => sum + e.plays), 2);
    c.dispose();
  });
  test('device media controls use the same queue and playback state', () async {
    final c = MusicController(FakeRepository(), FakeAudio());
    final handler = DeviceMediaHandler(c);
    await c.playTracks([a, b], 0);
    expect(handler.mediaItem.value?.id, a.id);
    expect(handler.playbackState.value.playing, true);
    expect(handler.queue.value.map((item) => item.id), [a.id, b.id]);
    await handler.skipToNext();
    expect(c.current?.id, b.id);
    await handler.pause();
    expect(c.audio.playing, false);
    await handler.setShuffleMode(AudioServiceShuffleMode.all);
    expect(c.shuffle, true);
    await handler.seek(const Duration(seconds: 12));
    expect(c.audio.position.inSeconds, 12);
    await handler.stop();
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.idle,
    );
    c.dispose();
  });
  test(
    'Wrapped groups actual listening by selected year, track, artist and month',
    () {
      final report = WrappedSummary([
        ListenDay(
          track: a,
          day: DateTime(2026, 1, 2),
          milliseconds: 120000,
          plays: 1,
        ),
        ListenDay(
          track: b,
          day: DateTime(2026, 1, 2),
          milliseconds: 60000,
          plays: 1,
        ),
        ListenDay(
          track: a,
          day: DateTime(2026, 2, 3),
          milliseconds: 180000,
          plays: 2,
        ),
        ListenDay(
          track: b,
          day: DateTime(2025, 1, 2),
          milliseconds: 9999999,
          plays: 99,
        ),
      ], 2026);
      expect(report.minutes, 6);
      expect(report.plays, 4);
      expect(report.uniqueSongs, 2);
      expect(report.uniqueArtists, 1);
      expect(report.days, 2);
      expect(report.topTracks.first.id, a.id);
      expect(report.monthlyMinutes.take(2), [3, 3]);
      expect(report.artistTime.values.single, 360000);
      expect(WrappedSummary([], 2026).minutes, 0);
    },
  );
  for (final width in [320.0, 800.0, 1280.0]) {
    testWidgets('all new screens and playback panels fit at $width pixels', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = FakeRepository()..liked = [a, b];
      repo.listening.add(
        ListenDay(
          track: a,
          day: DateTime.now(),
          milliseconds: 300000,
          plays: 2,
        ),
      );
      final c = MusicController(repo, FakeAudio());
      await tester.pumpWidget(MusicApp(controller: c));
      await tester.pumpAndSettle();
      for (final page in [
        MusicPage.home,
        MusicPage.liked,
        MusicPage.downloads,
        MusicPage.history,
        MusicPage.wrapped,
        MusicPage.settings,
        MusicPage.artist,
      ]) {
        if (page == MusicPage.artist) {
          c.openArtist('Artist');
        } else {
          c.navigate(page);
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: page.name);
      }
      await c.playTracks([a, b], 0);
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(Scaffold).first);
      unawaited(showNowPlaying(context, c));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Queue').last);
      await tester.pumpAndSettle();
      expect(find.text('Play queue'), findsOneWidget);
      expect(tester.takeException(), isNull);
      Navigator.of(tester.element(find.text('Play queue'))).pop();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      unawaited(
        editPlaylistDialog(
          context,
          c,
          Playlist(id: 'p', name: 'Test', tracks: [a, b]),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  }
}
