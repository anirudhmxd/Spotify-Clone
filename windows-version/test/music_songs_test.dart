import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythm/models/music.dart';
import 'package:rhythm/services/music_songs_client.dart';
import 'package:rhythm/services/youtube_catalog.dart';
import 'package:rhythm/services/stream_resolver.dart';

Map<String, dynamic> fixture(String name) =>
    jsonDecode(File('test/fixtures/$name.json').readAsStringSync())
        as Map<String, dynamic>;
Map<String, dynamic> copy(dynamic value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
List<dynamic> rows(Map<String, dynamic> data) =>
    data['contents']['musicShelfRenderer']['contents'] as List;
Map<String, dynamic> row(Map<String, dynamic> data) =>
    rows(data).first['musicResponsiveListItemRenderer'] as Map<String, dynamic>;
Map<String, dynamic> endpoint(Map<String, dynamic> row) =>
    row['overlay']['musicItemThumbnailOverlayRenderer']['content']['musicPlayButtonRenderer']['playNavigationEndpoint']['watchEndpoint']
        as Map<String, dynamic>;
void videoType(Map<String, dynamic> endpoint, String type) =>
    endpoint['watchEndpointMusicSupportedConfigs']['watchEndpointMusicConfig']['musicVideoType'] =
        type;

void main() {
  test(
    'song search reads artists, album, duration and a filtered continuation',
    () async {
      final calls = <Map<String, dynamic>>[];
      final client = MusicSongsClient(
        request: (path, body) async {
          expect(path, 'search');
          calls.add(body);
          return fixture('music_search');
        },
      );
      addTearDown(client.close);
      final page = await client.search('Daft Punk');
      expect(page.tracks, hasLength(2));
      final song = page.tracks.first;
      expect(song.id, '4D7u5KF7SP8');
      expect(song.artist, contains('Daft Punk'));
      expect(song.album, 'Random Access Memories');
      expect(song.durationMs, 370000);
      expect(song.artwork, startsWith('https://'));
      expect(song.isSong, isTrue);
      expect(Track.fromJson(song.toJson()).isSong, isTrue);
      expect(page.continuation, 'next-page');
      await client.search('Daft Punk', continuation: page.continuation);
      expect(
        calls.every((b) => b['params'] == MusicSongsClient.songsFilter),
        isTrue,
      );
      expect(calls.last['continuation'], 'next-page');
    },
  );

  test(
    'video, podcast, playlist and unknown types never become song results',
    () async {
      final data = fixture('music_search');
      final template = copy(row(data));
      rows(data).clear();
      for (final type in [
        'MUSIC_VIDEO_TYPE_OMV',
        'MUSIC_VIDEO_TYPE_UGC',
        'MUSIC_VIDEO_TYPE_PODCAST_EPISODE',
        'UNKNOWN',
      ]) {
        final video = copy(template);
        videoType(endpoint(video), type);
        rows(data).add({'musicResponsiveListItemRenderer': video});
      }
      final playlist = copy(template);
      endpoint(playlist).clear();
      endpoint(playlist)['playlistId'] = 'PL_not_a_song';
      rows(data).add({'musicResponsiveListItemRenderer': playlist});
      final client = MusicSongsClient(request: (_, _) async => data);
      addTearDown(client.close);
      // Even an entirely rejected page must not fall back to unfiltered results.
      expect((await client.search('official audio')).tracks, isEmpty);
    },
  );

  test(
    'extra non-song shelves are rejected even when they contain song endpoints',
    () async {
      final data = fixture('music_search');
      data['contents']['musicShelfRenderer']['title']['runs'][0]['text'] =
          'Videos';
      final client = MusicSongsClient(request: (_, _) async => data);
      addTearDown(client.close);
      expect((await client.search('test')).tracks, isEmpty);
    },
  );

  test(
    'radio ignores videos, unavailable tracks and video counterparts',
    () async {
      final data = fixture('music_radio');
      final contents =
          data['contents']['playlistPanelRenderer']['contents'] as List;
      final video = copy(contents[1]);
      videoType(
        video['playlistPanelVideoRenderer']['navigationEndpoint']['watchEndpoint']
            as Map<String, dynamic>,
        'MUSIC_VIDEO_TYPE_OMV',
      );
      final unavailable = copy(contents[2]);
      unavailable['playlistPanelVideoRenderer']['unplayableText'] = {
        'runs': [
          {'text': 'Unavailable'},
        ],
      };
      final primary = copy(contents[1]);
      contents
        ..clear()
        ..add(video)
        ..add(unavailable)
        ..add({
          'playlistPanelVideoWrapperRenderer': {
            'primaryRenderer': primary,
            'counterpart': [
              {'counterpartRenderer': video},
            ],
          },
        });
      final client = MusicSongsClient(
        request: (path, body) async {
          expect(path, 'next');
          expect(body['isAudioOnly'], isTrue);
          return data;
        },
      );
      addTearDown(client.close);
      final result = await client.related('4D7u5KF7SP8');
      expect(result, hasLength(1));
      expect(result.single.id, 'qPRNIHxLhmc');
      expect(result.single.isSong, isTrue);
    },
  );

  test(
    'legacy verification rejects video types and caches its result',
    () async {
      var calls = 0;
      final client = MusicSongsClient(
        request: (path, body) async {
          expect(path, 'player');
          calls++;
          return {
            'videoDetails': {
              'videoId': body['videoId'],
              'musicVideoType': 'MUSIC_VIDEO_TYPE_OMV',
            },
          };
        },
      );
      addTearDown(client.close);
      expect(await client.isSong('videotrack1'), isFalse);
      expect(await client.isSong('videotrack1'), isFalse);
      expect(await client.isSong('PL_long_playlist'), isFalse);
      expect(calls, 1);
    },
  );

  test(
    'catalog rejects playlist links and cached legacy videos before resolving',
    () async {
      final dir = await Directory.systemTemp.createTemp('rhythm-song-guard-');
      var requests = 0;
      var resolves = 0;
      final catalog = YoutubeCatalog(
        cacheDirectory: () async => dir,
        musicClientFactory: () => MusicSongsClient(
          request: (_, body) async {
            requests++;
            return {
              'videoDetails': {
                'videoId': body['videoId'],
                'musicVideoType': 'MUSIC_VIDEO_TYPE_OMV',
              },
            };
          },
        ),
        streamResolver: StreamResolver(
          direct: (_) async {
            resolves++;
            return 'https://audio.example/test';
          },
        ),
      );
      addTearDown(() async {
        catalog.dispose();
        await dir.delete(recursive: true);
      });
      await expectLater(
        catalog.search('https://youtube.com/playlist?list=PL123', 0),
        throwsArgumentError,
      );
      expect(requests, 0);
      await File('${dir.path}/videotrack1.m4a').writeAsBytes([1, 2, 3]);
      const video = Track(
        id: 'videotrack1',
        title: 'An old music video',
        artist: 'Artist',
        album: '',
        artwork: '',
        stream: '',
      );
      await expectLater(catalog.resolveAudio(video), throwsStateError);
      await expectLater(catalog.download(video, dir), throwsStateError);
      expect(resolves, 0);
      expect(requests, 1);
      expect(await File('${dir.path}/videotrack1.m4a').exists(), isTrue);
    },
  );

  test(
    'song radio outages use song search without general video fallback',
    () async {
      final calls = <String>[];
      final catalog = YoutubeCatalog(
        musicClientFactory: () => MusicSongsClient(
          request: (path, body) async {
            calls.add(path);
            if (path == 'next') throw const SocketException('Unavailable');
            return fixture('music_search');
          },
        ),
      );
      addTearDown(catalog.dispose);
      const seed = Track(
        id: 'seed0000001',
        title: 'Seed',
        artist: 'Daft Punk',
        album: '',
        artwork: '',
        stream: '',
        isMusic: true,
      );
      final results = await catalog.related(seed);
      expect(results, isNotEmpty);
      expect(results.every((t) => t.isSong), isTrue);
      expect(calls, ['next', 'search']);
    },
  );
}
