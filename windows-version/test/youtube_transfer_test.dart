import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class _LiveHttp extends HttpOverrides {}

class _ManifestClient extends StreamClient {
  _ManifestClient(super.httpClient, this.info);
  final AudioOnlyStreamInfo info;
  int refreshes = 0;
  @override
  Future<StreamManifest> getManifest(
    dynamic videoId, {
    bool fullManifest = false,
    List<YoutubeApiClient>? ytClients,
    bool requireWatchPage = true,
    bool audioOnly = false,
    bool validateStreams = true,
  }) async {
    refreshes++;
    return StreamManifest([info]);
  }
}

void main() {
  for (final android in [false, true]) {
    test(
      'library range stays within small audio file bounds (Android=$android)',
      () async {
        await HttpOverrides.runWithHttpOverrides(() async {
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          final bytes = List.generate(16, (i) => i);
          String? range;
          server.listen((request) async {
            range = android
                ? request.headers.value('Range')
                : request.uri.queryParameters['range'];
            request.response.statusCode = 206;
            request.response.add(bytes);
            await request.response.close();
          });
          final http = YoutubeHttpClient();
          final info = AudioOnlyStreamInfo.fromJson({
            'videoId': {'value': 'seed0000001'},
            'tag': 139,
            'url':
                'http://127.0.0.1:${server.port}/audio?c=${android ? 'ANDROID' : 'TEST'}',
            'container': {'name': 'mp4'},
            'size': {'totalBytes': 16},
            'bitrate': {'bitsPerSecond': 48000},
            'audioCodec': 'mp4a.40.2',
            'codec': 'audio/mp4',
            'qualityLabel': 'test',
            'fragments': [],
            'audioTrack': null,
          });
          final client = _ManifestClient(http, info);
          try {
            final result = await client
                .get(info)
                .expand((bytes) => bytes)
                .toList();
            expect(result, bytes);
            expect(range, android ? 'bytes=0-15' : '0-15');
          } finally {
            http.close();
            await server.close(force: true);
          }
        }, _LiveHttp());
      },
    );
  }
  test('persistent HTTP 403 refreshes once then reports failure', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.statusCode = 403;
        await request.response.close();
      });
      final http = YoutubeHttpClient();
      final info = AudioOnlyStreamInfo.fromJson({
        'videoId': {'value': 'seed0000001'},
        'tag': 139,
        'url': 'http://127.0.0.1:${server.port}/audio',
        'container': {'name': 'mp4'},
        'size': {'totalBytes': 16},
        'bitrate': {'bitsPerSecond': 48000},
        'audioCodec': 'mp4a.40.2',
        'codec': 'audio/mp4',
        'qualityLabel': 'test',
        'fragments': [],
        'audioTrack': null,
      });
      final client = _ManifestClient(http, info);
      try {
        await expectLater(
          client.get(info).toList(),
          throwsA(isA<FatalFailureException>()),
        );
        expect(client.refreshes, 1);
        expect(requests, 2);
      } finally {
        http.close();
        await server.close(force: true);
      }
    }, _LiveHttp());
  });
}
