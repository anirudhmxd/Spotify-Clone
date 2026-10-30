// Optional complete-file check: --dart-define=LIVE_DOWNLOAD=true.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythm_app/services/data_saving_downloader.dart';
import 'package:rhythm_app/services/audio_diagnostics.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class _LiveHttp extends HttpOverrides {}

class _Client extends YoutubeAudioDownloadClient {
  AudioOnlyStreamInfo? selected;
  @override
  Stream<List<int>> read(AudioOnlyStreamInfo info) {
    selected = info;
    return super.read(info);
  }
}

void main() {
  test(
    'downloads the entire smallest compatible audio with YoutubeExplode',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final directory = await Directory.systemTemp.createTemp(
          'rhythm-live-download-',
        );
        final client = _Client();
        final downloader = DataSavingDownloader(
          clientFactory: () => client,
          appleCompatible: true,
        );
        try {
          final timer = Stopwatch()..start();
          final file = await downloader.downloadSmallestAudio(
            const String.fromEnvironment(
              'VIDEO_ID',
              defaultValue: 'plnfIj7dkJE',
            ),
            directory: directory,
          );
          final bytes = await file.length();
          expect(bytes, client.selected!.size.totalBytes);
          expect(bytes, greaterThan(10000));
          expect(file.path, endsWith('.m4a'));
          // ignore: avoid_print
          print(
            'Complete YoutubeExplode audio: $bytes bytes, ${client.selected!.bitrate.bitsPerSecond} bps, ${timer.elapsedMilliseconds} ms',
          );
        } catch (error) {
          fail(AudioDiagnostics.redact(error));
        } finally {
          downloader.dispose();
          await directory.delete(recursive: true);
        }
      }, _LiveHttp());
    },
    skip: !const bool.fromEnvironment('LIVE_DOWNLOAD'),
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
