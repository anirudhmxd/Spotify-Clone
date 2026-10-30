import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythm_app/brand.dart';
import 'package:rhythm_app/main.dart';
import 'package:rhythm_app/music_controller.dart';
import 'package:rhythm_app/widgets/play_button.dart';
import 'fakes.dart';

void main() {
  for (final width in [360.0, 800.0, 1280.0]) {
    testWidgets('home, search and player fit at width $width', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = FakeRepository();
      final audio = FakeAudio();
      final c = MusicController(repo, audio);
      await tester.pumpWidget(MusicApp(controller: c));
      await tester.pumpAndSettle();
      expect(find.text('Your daily rhythm'), findsOneWidget);
      expect(tester.takeException(), isNull);
      c.navigate(MusicPage.search);
      c.search('A favourite song', immediate: true);
      await tester.pumpAndSettle();
      expect(find.text('A favourite song'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final loading = Completer<String>();
      repo.onResolve = (_, _) => loading.future;
      await tester.tap(find.byTooltip('Play A favourite song'));
      await tester.pump();
      expect(find.byIcon(Icons.stop_rounded), findsNWidgets(2));
      final spinner = tester.widget<CircularProgressIndicator>(
        find.descendant(
          of: find.byType(PlayButton).first,
          matching: find.byType(CircularProgressIndicator),
        ),
      );
      expect(spinner.color, RhythmBrand.ink);
      expect(spinner.color, isNot(RhythmBrand.violet));
      loading.complete('file:///tmp/song.m4a');
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.pause_rounded), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      audio.tick(const Duration(seconds: 30));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Pause A favourite song'));
      await tester.pumpAndSettle();
      expect(audio.playing, isFalse);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  }

  testWidgets(
    'only the upcoming song is prepared, and queue edits update the choice',
    (tester) async {
      final repo = FakeRepository();
      final c = MusicController(repo, FakeAudio());
      addTearDown(c.dispose);
      await c.playTracks([
        song('first000001'),
        song('second00001'),
        song('third000001'),
      ], 0);
      await tester.pump(const Duration(milliseconds: 350));
      expect(repo.prepared, ['second00001']);
      c.reorderQueue(2, 1);
      await tester.pump(const Duration(milliseconds: 350));
      expect(repo.prepared, ['second00001', 'third000001']);
      c.clearUpcoming();
      await tester.pump(const Duration(seconds: 1));
      expect(repo.prepared.length, 2);
    },
  );

  testWidgets('offline mode does not prepare remote audio', (tester) async {
    final repo = FakeRepository();
    final c = MusicController(repo, FakeAudio());
    addTearDown(c.dispose);
    c.settings = c.settings.copyWith(offline: true);
    await c.playTracks([song('first000001'), song('second00001')], 0);
    await tester.pump(const Duration(seconds: 1));
    expect(repo.prepared, isEmpty);
  });

  testWidgets(
    'unreadable search metadata gets a useful message without a parser dump',
    (tester) async {
      final repo = FakeRepository()
        ..onSearch = (_, _) async =>
            throw const FormatException('Invalid radix-10 number', 'Streamed');
      final c = MusicController(repo, FakeAudio());
      await tester.pumpWidget(MusicApp(controller: c));
      await tester.pumpAndSettle();
      c.navigate(MusicPage.search);
      c.search('Hip hop music', immediate: true);
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Some music information could not be read. Please try again.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('radix'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets('typing debounces a burst into one search', (tester) async {
    final repo = FakeRepository();
    final c = MusicController(repo, FakeAudio());
    await tester.pumpWidget(MusicApp(controller: c));
    await tester.pumpAndSettle();
    c.navigate(MusicPage.search);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'd');
    await tester.pump(const Duration(milliseconds: 60));
    await tester.enterText(find.byType(TextField), 'da');
    await tester.pump(const Duration(milliseconds: 60));
    await tester.enterText(find.byType(TextField), 'dance');
    await tester.pump(const Duration(milliseconds: 180));
    await tester.pumpAndSettle();
    expect(repo.searches, ['dance/0']);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
