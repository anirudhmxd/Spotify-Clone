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
        final hipHop = await catalog.search('Hip hop music', 0);
        expect(hipHop.tracks, isNotEmpty);
        // ignore: avoid_print
        print(
          'Hip hop music: ${hipHop.tracks.length} results in ${timer.elapsedMilliseconds} ms',
        );
        timer.reset();
        final results = await catalog.search('Daft Punk Get Lucky', 0);
        expect(results.tracks, isNotEmpty);
        expect(results.tracks.every((track) => track.isSong), isTrue);
        if (results.hasMore) {
          final nextPage = await catalog.search('Daft Punk Get Lucky', 1);
          expect(nextPage.tracks, isNotEmpty);
          expect(nextPage.tracks.every((track) => track.isSong), isTrue);
          // ignore: avoid_print
          print('Song-only pagination: ${nextPage.tracks.length} songs');
        }
        // ignore: avoid_print
        print(
          'Search: ${results.tracks.length} results in ${timer.elapsedMilliseconds} ms',
        );
        timer.reset();
        final seed = results.tracks.first;
        final related = await catalog.related(seed);
        expect(related, isNotEmpty);
        expect(related.every((track) => track.isSong), isTrue);
        expect(related.every((track) => track.id != seed.id), isTrue);
        // ignore: avoid_print
        print(
          'Related: ${related.length} songs in ${timer.elapsedMilliseconds} ms',
        );
        timer.reset();
        try {
          final manifest = await streams.videos.streamsClient
              .getManifest(
                seed.id,
                requireWatchPage: false,
                audioOnly: true,
                validateStreams: false,
              )
              .timeout(const Duration(seconds: 6));
          expect(
            manifest.audioOnly.where((s) => s.container.name == 'mp4'),
            isNotEmpty,
          );
          // ignore: avoid_print
          print('Stream available in ${timer.elapsedMilliseconds} ms');
          final http = HttpClient();
          try {
            final stream = manifest.audioOnly.firstWhere(
              (s) => s.container.name == 'mp4',
            );
            final request = await http
                .getUrl(stream.url)
                .timeout(const Duration(seconds: 5));
            request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-65535');
            final response = await request.close().timeout(
              const Duration(seconds: 5),
            );
            expect([200, 206], contains(response.statusCode));
            final bytes = await response.first.timeout(
              const Duration(seconds: 5),
            );
            expect(bytes, isNotEmpty);
            // ignore: avoid_print
            print(
              'Direct stream delivered ${bytes.length} initial audio bytes',
            );
          } finally {
            http.close(force: true);
          }
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
