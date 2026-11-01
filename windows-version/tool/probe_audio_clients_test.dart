// Diagnostic only: --dart-define=LIVE_PROBE=true. Does not save songs.
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:rhythm/services/audio_diagnostics.dart';
import 'package:rhythm/services/data_saving_downloader.dart';

class _LiveHttp extends HttpOverrides {}

void main() {
  test(
    'compare audio client responses',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        const id = String.fromEnvironment(
          'VIDEO_ID',
          defaultValue: '3Lo8HBwOrQM',
        );
        final profiles = {
          'visionos': YoutubeApiClient.visionOs,
          'android_sdkless': YoutubeApiClient.androidSdkless,
          'android_vr': YoutubeApiClient.androidVr,
          'ios': YoutubeApiClient.ios,
          'android_music': YoutubeApiClient.androidMusic,
          'media_connect': YoutubeApiClient.mediaConnect,
        };
        for (final profile in profiles.entries) {
          final yt = YoutubeExplode();
          final clock = Stopwatch()..start();
          StreamIterator<List<int>>? iterator;
          try {
            final manifest = await yt.videos.streamsClient
                .getManifest(
                  id,
                  ytClients: [profile.value],
                  requireWatchPage: false,
                )
                .timeout(const Duration(seconds: 8));
            final info = DataSavingDownloader.selectAudio(
              manifest.audioOnly,
              appleCompatible: true,
            );
            AudioDiagnostics.log(
              'probe.manifest',
              'profile=${profile.key} ms=${clock.elapsedMilliseconds} tag=${info.tag} bytes=${info.size.totalBytes}',
            );
            iterator = StreamIterator(yt.videos.streamsClient.get(info));
            final got = await iterator.moveNext().timeout(
              const Duration(seconds: 6),
            );
            AudioDiagnostics.log(
              'probe.body',
              'profile=${profile.key} ms=${clock.elapsedMilliseconds} got=$got bytes=${got ? iterator.current.length : 0}',
            );
          } catch (error) {
            AudioDiagnostics.log(
              'probe.failed',
              'profile=${profile.key} ms=${clock.elapsedMilliseconds} error=$error',
            );
          } finally {
            yt.close();
            try {
              await iterator?.cancel().timeout(const Duration(seconds: 1));
            } catch (_) {}
          }
        }
      }, _LiveHttp());
    },
    skip: !const bool.fromEnvironment('LIVE_PROBE'),
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
