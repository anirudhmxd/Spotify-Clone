import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythm_app/music_controller.dart';
import 'package:rhythm_app/widgets/playback_panels.dart';
import 'fakes.dart';

class _SeekAudio extends FakeAudio {
  final seeks = <Duration>[];
  Completer<void>? gate;
  bool applyPosition = false;
  bool fail = false;
  @override
  Future<void> seek(Duration value) async {
    seeks.add(value);
    await gate?.future;
    if (fail) throw StateError('Native seek failed');
    if (applyPosition) position = value;
  }
}

Widget player(MusicController c) => MaterialApp(
  home: Scaffold(
    body: Column(
      children: [
        PlaybackTimeline(c: c),
        ListenableBuilder(
          listenable: c,
          builder: (_, _) => PlaybackControls(c: c),
        ),
      ],
    ),
  ),
);

void main() {
  testWidgets(
    'drag previews locally; one seek holds its target through stale iOS positions',
    (tester) async {
      final audio = _SeekAudio()..gate = Completer<void>();
      final c = MusicController(FakeRepository(), audio);
      addTearDown(c.dispose);
      await c.playTracks([song('seed0000001')], 0);
      audio.tick(const Duration(seconds: 30));
      await tester.pumpWidget(player(c));
      var slider = tester.widget<Slider>(find.byType(Slider));
      slider.onChangeStart!(30000);
      slider.onChanged!(90000);
      slider.onChanged!(100000);
      audio.tick(const Duration(seconds: 31));
      await tester.pump();
      slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.value, 100000);
      expect(audio.seeks, isEmpty);
      slider.onChangeEnd!(100000);
      await tester.pump();
      expect(audio.seeks, [const Duration(seconds: 100)]);
      expect(find.byType(CircularProgressIndicator), findsNWidgets(2));
      expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
      audio.tick(const Duration(seconds: 32));
      await tester.pump();
      expect(tester.widget<Slider>(find.byType(Slider)).value, 100000);
      audio.gate!.complete();
      await tester.pump();
      // Native seek completion can precede the new position/buffer event.
      expect(c.seeking, isTrue);
      audio.loading = true;
      audio.tick(const Duration(seconds: 100));
      await tester.pump();
      expect(c.seeking, isTrue);
      audio.loading = false;
      audio.states.add(null);
      await tester.pump();
      expect(c.seeking, isFalse);
      expect(tester.widget<Slider>(find.byType(Slider)).value, 100000);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      audio.tick(const Duration(seconds: 101));
      await tester.pump();
      expect(tester.widget<Slider>(find.byType(Slider)).value, 101000);
    },
  );

  testWidgets('loading and buffering show a spinner and disable seeking', (
    tester,
  ) async {
    final repo = FakeRepository();
    final gate = Completer<String>();
    repo.onResolve = (_, _) => gate.future;
    final audio = _SeekAudio();
    final c = MusicController(repo, audio);
    addTearDown(c.dispose);
    final playback = c.playTracks([song('seed0000001')], 0);
    await tester.pumpWidget(player(c));
    expect(find.byType(CircularProgressIndicator), findsNWidgets(2));
    expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
    await c.seek(const Duration(seconds: 80));
    expect(audio.seeks, isEmpty);
    gate.complete('file:///tmp/song.m4a');
    await playback;
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    audio.loading = true;
    audio.states.add(null);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNWidgets(2));
    expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
    audio.loading = false;
    audio.states.add(null);
    await tester.pump();
    expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNotNull);
  });

  testWidgets(
    'seek failure releases its loading state and restores actual position',
    (tester) async {
      final audio = _SeekAudio()..fail = true;
      final c = MusicController(FakeRepository(), audio);
      addTearDown(c.dispose);
      await c.playTracks([song('seed0000001')], 0);
      audio.tick(const Duration(seconds: 30));
      await c.seek(const Duration(seconds: 100));
      expect(c.seeking, isFalse);
      expect(c.playbackPosition.value, const Duration(seconds: 30));
      expect(c.notice, contains('Could not seek'));
    },
  );

  testWidgets(
    'a seek without native confirmation times out instead of sticking forever',
    (tester) async {
      final audio = _SeekAudio();
      final c = MusicController(FakeRepository(), audio);
      addTearDown(c.dispose);
      await c.playTracks([song('seed0000001')], 0);
      await c.seek(const Duration(seconds: 100));
      expect(c.seeking, isTrue);
      await tester.pump(const Duration(seconds: 10));
      expect(c.seeking, isFalse);
      expect(c.notice, contains('Seeking took too long'));
    },
  );

  testWidgets('changing songs clears an old seek and its late completion', (
    tester,
  ) async {
    final audio = _SeekAudio()..gate = Completer<void>();
    final c = MusicController(FakeRepository(), audio);
    addTearDown(c.dispose);
    await c.playTracks([song('seed0000001')], 0);
    final seek = c.seek(const Duration(seconds: 100));
    await tester.pump();
    await c.playTracks([song('seed0000002')], 0);
    expect(c.seeking, isFalse);
    audio.gate!.complete();
    await seek;
    expect(c.current!.id, 'seed0000002');
    expect(c.playbackPosition.value, Duration.zero);
  });
  testWidgets(
    'buffering during a drag releases the preview instead of leaving it stuck',
    (tester) async {
      final audio = _SeekAudio();
      final c = MusicController(FakeRepository(), audio);
      addTearDown(c.dispose);
      await c.playTracks([song('seed0000001')], 0);
      audio.tick(const Duration(seconds: 20));
      await tester.pumpWidget(player(c));
      final slider = tester.widget<Slider>(find.byType(Slider));
      slider.onChangeStart!(20000);
      slider.onChanged!(100000);
      await tester.pump();
      audio.loading = true;
      audio.states.add(null);
      await tester.pump();
      expect(tester.widget<Slider>(find.byType(Slider)).value, 20000);
      audio.loading = false;
      audio.states.add(null);
      audio.tick(const Duration(seconds: 21));
      await tester.pump();
      expect(tester.widget<Slider>(find.byType(Slider)).value, 21000);
      expect(audio.seeks, isEmpty);
    },
  );

  testWidgets('cancelling a pending seek restores the paused position', (
    tester,
  ) async {
    final audio = _SeekAudio()..gate = Completer<void>();
    final c = MusicController(FakeRepository(), audio);
    addTearDown(c.dispose);
    await c.playTracks([song('seed0000001')], 0);
    audio.tick(const Duration(seconds: 20));
    final seek = c.seek(const Duration(seconds: 100));
    await tester.pump();
    await c.togglePlay();
    expect(c.seeking, isFalse);
    expect(c.playbackPosition.value, const Duration(seconds: 20));
    expect(audio.playing, isFalse);
    audio.gate!.complete();
    await seek;
    expect(c.playbackPosition.value, const Duration(seconds: 20));
  });
  testWidgets('rapid seek requests keep only the latest waiting target', (
    tester,
  ) async {
    final audio = _SeekAudio()
      ..gate = Completer<void>()
      ..applyPosition = true;
    final c = MusicController(FakeRepository(), audio);
    addTearDown(c.dispose);
    await c.playTracks([song('seed0000001')], 0);
    final first = c.seek(const Duration(seconds: 10));
    await tester.pump();
    final second = c.seek(const Duration(seconds: 20));
    final last = c.seek(const Duration(seconds: 30));
    expect(c.playbackPosition.value, const Duration(seconds: 30));
    audio.gate!.complete();
    await Future.wait([first, second, last]);
    expect(audio.seeks, [
      const Duration(seconds: 10),
      const Duration(seconds: 30),
    ]);
    expect(c.seeking, isFalse);
    expect(audio.position, const Duration(seconds: 30));
  });
  testWidgets('completion during a seek to the end advances exactly once', (
    tester,
  ) async {
    final audio = _SeekAudio()..gate = Completer<void>();
    final c = MusicController(FakeRepository(), audio);
    addTearDown(c.dispose);
    await c.playTracks([song('seed0000001'), song('seed0000002')], 0);
    final seek = c.seek(const Duration(seconds: 180));
    await tester.pump();
    audio.tick(const Duration(seconds: 180));
    audio.completed.add(null);
    expect(c.current!.id, 'seed0000001');
    audio.gate!.complete();
    await seek;
    await tester.pump();
    expect(c.current!.id, 'seed0000002');
    expect(audio.files, hasLength(2));
  });
}
