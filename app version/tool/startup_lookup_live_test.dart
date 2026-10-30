// Optional lookup-only diagnostic: --dart-define=LIVE_LOOKUP=true.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythm_app/services/youtube_catalog.dart';
import 'package:rhythm_app/services/audio_diagnostics.dart';

class _LiveHttp extends HttpOverrides {}

void main() {
  test(
    'cold, shared-session and cached audio URL lookup',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final directory = await Directory.systemTemp.createTemp(
          'rhythm-lookup-live-',
        );
        final catalog = YoutubeCatalog(cacheDirectory: () async => directory);
        try {
          final songs = (await catalog.search('Daft Punk Get Lucky', 0)).tracks;
          for (final track in [songs[0], songs[1], songs[1]]) {
            final id = track.id;
            final clock = Stopwatch()..start();
            final source = await catalog.resolveAudio(track);
            expect(source, startsWith('https://'));
            // ignore: avoid_print
            print('Lookup $id: ${clock.elapsedMilliseconds} ms');
          }
          expect(await directory.list().toList(), isEmpty);
        } catch (error) {
          fail(AudioDiagnostics.redact(error));
        } finally {
          catalog.dispose();
          await directory.delete(recursive: true);
        }
      }, _LiveHttp());
    },
    skip: !const bool.fromEnvironment('LIVE_LOOKUP'),
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
