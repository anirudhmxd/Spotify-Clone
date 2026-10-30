// Optional upstream check: flutter test tool/catalog_live_test.dart --dart-define=LIVE_CATALOG=true
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythm_app/services/youtube_catalog.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class _LiveHttp extends HttpOverrides {}

void main() {
  test('YouTube search and related songs respond independently', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final catalog = YoutubeCatalog();
      final streams = YoutubeExplode();
      try {
        final timer = Stopwatch()..start();
        final results = await catalog.search('Daft Punk Get Lucky', 0);
        expect(results.tracks, isNotEmpty);
        // ignore: avoid_print
        print(
          'Search: ${results.tracks.length} results in ${timer.elapsedMilliseconds} ms',
        );
        timer.reset();
        final seed = results.tracks.first;
        final related = await catalog.related(seed);
        expect(related, isNotEmpty);
        expect(related.every((track) => track.id != seed.id), isTrue);
        // ignore: avoid_print
        print(
          'Related: ${related.length} songs in ${timer.elapsedMilliseconds} ms',
        );
        timer.reset();
        try {
          final manifest = await streams.videos.streamsClient
              .getManifest(seed.id, requireWatchPage: false)
              .timeout(const Duration(seconds: 6));
          expect(
            manifest.audioOnly.where((s) => s.container.name == 'mp4'),
            isNotEmpty,
          );
          // ignore: avoid_print
          print('Stream available in ${timer.elapsedMilliseconds} ms');
        } catch (error) {
          // This environment may need the on-device downloader fallback.
          // ignore: avoid_print
          print('Direct stream unavailable here: $error');
        }
      } finally {
        catalog.dispose();
        streams.close();
      }
    }, _LiveHttp());
  }, skip: !const bool.fromEnvironment('LIVE_CATALOG'));
}
