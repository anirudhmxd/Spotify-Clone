import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class _Http extends Fake implements YoutubeHttpClient {
  final requests = <String>[];
  bool includeAudio = true;
  int heads = 0;
  @override
  bool get closed => false;
  @override
  Future<String> getString(
    dynamic url, {
    Map<String, String> headers = const {},
    bool validate = true,
  }) async {
    requests.add(url.toString());
    if (url.toString().endsWith('/sw.js_data')) {
      final fields = List<dynamic>.filled(14, null)..[13] = 'visitor';
      final body = jsonEncode([
        [
          null,
          null,
          [
            [fields],
          ],
        ],
      ]);
      return ")]}'$body";
    }
    if (url == 'https://extra.example/dash') {
      return '<MPD><Period></Period></MPD>';
    }
    if (url == 'https://extra.example/hls') {
      return '#EXTM3U\n#EXT-X-INDEPENDENT-SEGMENTS\n'
          '#EXT-X-MEDIA:TYPE=AUDIO,URI="https://audio.example/itag/140/sgoap/clen%3D100%3Bdur%3D2.0"';
    }
    throw StateError('Unexpected request: $url');
  }

  @override
  Future<String> postString(
    dynamic url, {
    Map<String, dynamic>? body,
    Map<String, String> headers = const {},
    bool validate = true,
  }) async {
    requests.add('player');
    return jsonEncode({
      'playabilityStatus': {'status': 'OK'},
      'videoDetails': {'videoId': 'seed0000001'},
      'streamingData': {
        'adaptiveFormats': [
          // Parsing this video stream would cause an extra content-length lookup.
          {
            'itag': 137,
            'url': 'https://video.example/137',
            'mimeType': 'video/mp4; codecs="avc1.640028"',
            'bitrate': 1000000,
            'qualityLabel': '1080p',
          },
          if (includeAudio)
            {
              'itag': 139,
              'url': 'https://audio.example/139',
              'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
              'bitrate': 48000,
              'contentLength': '100',
              'audioQuality': 'AUDIO_QUALITY_LOW',
            },
        ],
        'dashManifestUrl': 'https://extra.example/dash',
        'hlsManifestUrl': 'https://extra.example/hls',
      },
    });
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #head) {
      heads++;
      throw StateError('HEAD validation requested');
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  test(
    'audio lookup needs only visitor and player requests when direct audio exists',
    () async {
      final http = _Http();
      final client = StreamClient(http);
      final manifest = await client.getManifest(
        'seed0000001',
        requireWatchPage: false,
        audioOnly: true,
        validateStreams: false,
      );
      expect(manifest.streams, hasLength(1));
      expect(manifest.audioOnly.single.tag, 139);
      expect(http.requests, ['https://www.youtube.com/sw.js_data', 'player']);
      expect(http.heads, 0);
      // The same session only needs the player API for the next song.
      http.requests.clear();
      await client.getManifest(
        'seed0000002',
        requireWatchPage: false,
        audioOnly: true,
        validateStreams: false,
      );
      expect(http.requests, ['player']);
    },
  );
  test('normal validation stays enabled unless explicitly disabled', () async {
    final http = _Http();
    await expectLater(
      StreamClient(http).getManifest(
        'seed0000001',
        requireWatchPage: false,
        audioOnly: true,
        ytClients: [YoutubeApiClient.visionOs],
      ),
      throwsStateError,
    );
    expect(http.heads, 1);
  });
  test(
    'extra manifests remain available when no direct audio exists',
    () async {
      final http = _Http()..includeAudio = false;
      final manifest = await StreamClient(http).getManifest(
        'seed0000001',
        requireWatchPage: false,
        audioOnly: true,
        validateStreams: false,
        ytClients: [YoutubeApiClient.visionOs],
      );
      expect(manifest.streams, hasLength(1));
      expect(manifest.streams.single, isA<AudioStreamInfo>());
      expect(manifest.streams.single.tag, 140);
      expect(http.requests, contains('https://extra.example/dash'));
      expect(http.requests, contains('https://extra.example/hls'));
    },
  );
}
