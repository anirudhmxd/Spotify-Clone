// Render representative native Flutter screens using test-only listening data.
// Run: flutter test tool/preview_test.dart
import 'dart:io';
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
import '../test/music_test.dart' show FakeAudio, FakeRepository, a, b;

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
      final repo = FakeRepository()
        ..liked = [a, b]
        ..library = [
          Playlist(id: '1', name: 'Evening favourites', tracks: [a, b]),
        ];
      repo.listening.add(
        ListenDay(
          track: a,
          day: DateTime.now(),
          milliseconds: 3600000,
          plays: 12,
        ),
      );
      final c = MusicController(repo, FakeAudio());
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
      for (final page in [MusicPage.home, MusicPage.wrapped]) {
        c.navigate(page);
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
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  }
}
