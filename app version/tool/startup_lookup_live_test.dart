// Optional lookup-only diagnostic: --dart-define=LIVE_LOOKUP=true.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythm_app/models/music.dart';
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
          for (final id in ['x47TgeRJtH0', 'GJNdR_MKuDM', 'GJNdR_MKuDM']) {
            final track = Track(
              id: id,
              title: id,
              artist: '',
              album: '',
              artwork: '',
              stream: '',
            );
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
