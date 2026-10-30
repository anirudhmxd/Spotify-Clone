// Render representative native Flutter screens using test-only listening data.
// Run: flutter test tool/preview_test.dart
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythm_app/main.dart';
import 'package:rhythm_app/brand.dart';
import 'package:rhythm_app/models/experience.dart';
import 'package:rhythm_app/models/music.dart';
import 'package:rhythm_app/music_controller.dart';
import 'package:rhythm_app/widgets/equalizer_panel.dart';
import '../test/fakes.dart';

class _PreviewAudio extends FakeAudio {
  @override
  bool get supportsEqualizer => true;
  @override
  Future<List<double>> waveform({bool enabled = true}) async => enabled
      ? List.generate(64, (i) => sin(i * .65) * (.15 + .3 * sin(i * .15).abs()))
      : [];
}

void main() {
  for (final width in [390.0, 1280.0]) {
    testWidgets('render preview at $width', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        final path = const String.fromEnvironment(
          'PREVIEW_FONT',
          defaultValue: '/System/Library/Fonts/Supplemental/Arial.ttf',
        );
        final file = File(path);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          await (FontLoader(
            'Roboto',
          )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
        }
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      });
      final a = song('preview0001', 'A little closer');
      final b = song('preview0002', 'After the rain');
      final repo = FakeRepository()
        ..data = LibraryProfile(liked: [a, b], recent: [a, b]);
      final c = MusicController(repo, _PreviewAudio());
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MusicApp(controller: c),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        for (final size in [32, 40, 42, 44, 48, 52]) {
          await precacheImage(
            ResizeImage(const AssetImage(RhythmBrand.icon), width: size),
            boundary.currentContext!,
          );
        }
      });
      await tester.pumpAndSettle();
      for (final page in [MusicPage.home, MusicPage.search]) {
        c.navigate(page);
        if (page == MusicPage.search) {
          c.searchTracks = [a, b, song('preview0003', 'Midnight memories')];
          c.query = 'Evening favourites';
          await c.playRadio(a);
        }
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory('build/previews').create(recursive: true);
          await File(
            'build/previews/${page.name}-${width.toInt()}.png',
          ).writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
        expect(tester.takeException(), isNull);
      }
      c.playlists = [
        Playlist(id: 'evening', name: 'Evening favourites', tracks: [a, b]),
        Playlist(
          id: 'weekend',
          name: 'Weekend favourites',
          tracks: [b, song('preview0003', 'Midnight memories')],
        ),
        Playlist(id: 'slow', name: 'Slow mornings', tracks: [a]),
      ];
      c.navigate(MusicPage.library);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Blend playlists').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('blend-source-evening')));
      await tester.tap(find.byKey(const ValueKey('blend-source-weekend')));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          'build/previews/blend-${width.toInt()}.png',
        ).writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
      expect(tester.takeException(), isNull);
      // Static test audio provides a reproducible waveform for visual review.
      final eqController = MusicController(repo, _PreviewAudio());
      await eqController.playTracks([a], 0);
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: RhythmBrand.theme,
            home: Scaffold(
              appBar: AppBar(title: const Text('Equalizer')),
              body: SingleChildScrollView(
                child: EqualizerPanel(controller: eqController),
              ),
            ),
          ),
        ),
      );
      eqController.setEqualizerPreset('bass');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          'build/previews/equalizer-${width.toInt()}.png',
        ).writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      eqController.dispose();
      await tester.pump();
    });
  }
}
