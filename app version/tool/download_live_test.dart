// Optional full-file check, run with --dart-define=LIVE_DOWNLOAD=true.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythm_app/services/audio_file_downloader.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class _LiveHttp extends HttpOverrides {}

void main() {
  test(
    'downloads complete identical AAC files with one and three connections',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final youtube = YoutubeExplode();
        final directory = await Directory.systemTemp.createTemp(
          'rhythm-live-download-',
        );
        try {
          final manifest = await youtube.videos.streamsClient
              .getManifest(
                const String.fromEnvironment(
                  'VIDEO_ID',
                  defaultValue: 'dQw4w9WgXcQ',
                ),
                requireWatchPage: false,
              )
              .timeout(const Duration(seconds: 20));
          final streams =
              manifest.audioOnly
                  .where((s) => s.container.name == 'mp4')
                  .toList()
                ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
          expect(streams, isNotEmpty);
          final source = streams.first;
          final files = <File>[];
          for (final connections in [1, 3]) {
            final downloader = AudioFileDownloader(connections: connections);
            try {
              final timer = Stopwatch()..start();
              final file = File('${directory.path}/$connections.m4a');
              await downloader.download(source.url.toString(), file);
              final bytes = await file.length();
              expect(bytes, source.size.totalBytes);
              // ignore: avoid_print
              print(
                'Full download: $bytes bytes, $connections connections, ${timer.elapsedMilliseconds} ms',
              );
              files.add(file);
            } finally {
              downloader.dispose();
            }
          }
          expect(await files[0].readAsBytes(), await files[1].readAsBytes());
        } finally {
          youtube.close();
          await directory.delete(recursive: true);
        }
      }, _LiveHttp());
    },
    skip: !const bool.fromEnvironment('LIVE_DOWNLOAD'),
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
