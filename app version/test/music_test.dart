import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spotify_app/main.dart';
import 'package:spotify_app/models/music.dart';
import 'package:spotify_app/music_controller.dart';
import 'package:spotify_app/services/audio_engine.dart';
import 'package:spotify_app/services/music_api.dart';

class FakeAudio implements AudioEngine {
  final positionEvents = StreamController<Duration>.broadcast(sync: true);
  final stateEvents = StreamController<void>.broadcast(sync: true);
  final completionEvents = StreamController<void>.broadcast(sync: true);
  @override
  Duration position = Duration.zero;
  @override
  Duration duration = const Duration(seconds: 100);
  @override
  bool playing = false;
  @override
  bool loading = false;
  String? loaded;
  @override
  Stream<Duration> get positions => positionEvents.stream;
  @override
  Stream<void> get changes => stateEvents.stream;
  @override
  Stream<void> get completions => completionEvents.stream;
  @override
  Future<void> load(String url) async {
    loaded = url;
    position = Duration.zero;
  }

  @override
  Future<void> play() async {
    playing = true;
    stateEvents.add(null);
  }

  @override
  Future<void> pause() async {
    playing = false;
    stateEvents.add(null);
  }

  @override
  Future<void> seek(Duration value) async {
    position = value;
  }

  @override
  Future<void> setVolume(double value) async {}
  @override
  Future<void> setLoop(bool value) async {}
  @override
  Future<void> dispose() async {
    await positionEvents.close();
    await stateEvents.close();
    await completionEvents.close();
  }
}

const a = Track(
  id: 'aaaaaaaaaaa',
  title: 'First song',
  artist: 'Artist',
  album: 'Album',
  artwork: '',
  stream: '/api/stream/aaaaaaaaaaa',
);
const b = Track(
  id: 'bbbbbbbbbbb',
  title: 'Second song',
  artist: 'Artist',
  album: 'Album',
  artwork: '',
  stream: '/api/stream/bbbbbbbbbbb',
);
http.Response jsonResponse(Map<String, dynamic> data, [int status = 200]) =>
    http.Response(jsonEncode(data), status);
MusicController controller(
  Future<http.Response> Function(http.Request) handler, [
  FakeAudio? audio,
]) => MusicController(
  MusicApi('http://localhost:5000', clientFactory: () => MockClient(handler)),
  audio ?? FakeAudio(),
);
Future<void> tick() => Future<void>.delayed(Duration.zero);

void main() {
  test('clearing input invalidates in-flight search', () async {
    final response = Completer<http.Response>();
    final c = controller((_) => response.future);
    c.search('old', immediate: true);
    c.search('');
    response.complete(
      jsonResponse({
        'tracks': [a.toJson()],
        'hasMore': true,
      }),
    );
    await tick();
    expect(c.searchTracks, isEmpty);
    expect(c.searching, false);
    expect(c.hasMore, false);
    c.dispose();
  });
  test('new search wins even if earlier request finishes later', () async {
    final old = Completer<http.Response>();
    final c = controller((request) async {
      final query = jsonDecode(request.body)['query'];
      return query == 'old'
          ? old.future
          : jsonResponse({
              'tracks': [b.toJson()],
            });
    });
    c.search('old', immediate: true);
    c.search('new', immediate: true);
    await tick();
    old.complete(
      jsonResponse({
        'tracks': [a.toJson()],
      }),
    );
    await tick();
    expect(c.searchTracks.single.id, b.id);
    c.dispose();
  });
  test('pagination failure retries the same page', () async {
    final pages = <int>[];
    final c = controller((request) async {
      final page = jsonDecode(request.body)['page'] as int;
      pages.add(page);
      if (pages.length == 2) return jsonResponse({'error': 'offline'}, 502);
      return jsonResponse({
        'tracks': [(page == 0 ? a : b).toJson()],
        'hasMore': true,
      });
    });
    c.search('song', immediate: true);
    await tick();
    await c.loadMore();
    await c.loadMore();
    expect(pages, [0, 1, 1]);
    expect(c.searchTracks.map((t) => t.id), [a.id, b.id]);
    c.dispose();
  });
  test(
    'queue advances into recommendations and scores each play once',
    () async {
      var scores = 0;
      final audio = FakeAudio();
      final c = controller((request) async {
        if (request.url.path.endsWith('/score')) {
          scores++;
          return jsonResponse({'ok': true});
        }
        return jsonResponse({
          'songs': [b.toJson()],
        });
      }, audio);
      await c.playTracks([a], 0);
      await tick();
      audio.position = const Duration(seconds: 90);
      audio.positionEvents.add(audio.position);
      audio.positionEvents.add(audio.position);
      await tick();
      expect(scores, 1);
      await c.next(recommend: true);
      expect(c.current?.id, b.id);
      expect(c.queueIndex, 1);
      expect(audio.loaded, 'http://localhost:5000/api/stream/bbbbbbbbbbb');
      c.dispose();
    },
  );
  test('create playlist with a song preserves the pending track', () async {
    final paths = <String>[];
    final c = controller((request) async {
      paths.add(request.url.path);
      return jsonResponse({
        'playlist': {
          'id': 'p1',
          'name': 'My playlist',
          'tracks': request.url.path.endsWith('/tracks') ? [a.toJson()] : [],
        },
      });
    });
    await c.createPlaylist('My playlist', track: a);
    expect(paths, ['/api/playlists', '/api/playlists/p1/tracks']);
    expect(c.playlists.single.tracks.single.id, a.id);
    c.dispose();
  });
  testWidgets('stalled search times out and releases loading state', (
    tester,
  ) async {
    final pending = Completer<http.Response>();
    final c = controller((_) => pending.future);
    c.search('stalled', immediate: true);
    await tester.pump(const Duration(seconds: 21));
    expect(c.searching, false);
    expect(c.searchStatus, contains('took too long'));
    pending.complete(
      jsonResponse({
        'tracks': [a.toJson()],
      }),
    );
    await tester.pump();
    expect(c.searchTracks, isEmpty);
    c.dispose();
  });
  for (final width in [320.0, 800.0, 1280.0]) {
    testWidgets('search and navigation remain responsive at $width pixels', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final pending = Completer<http.Response>();
      final c = controller(
        (request) async => request.url.path == '/api/search'
            ? pending.future
            : jsonResponse({'playlists': [], 'songs': []}),
      );
      await tester.pumpWidget(MusicApp(controller: c));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'slow song');
      await tester.pump(const Duration(milliseconds: 350));
      expect(c.searching, true);
      if (width < 800) {
        await tester.tap(find.text('Library').last);
      } else {
        await tester.tap(find.text('Songs For You').first);
      }
      await tester.pump();
      expect(c.page, width < 800 ? MusicPage.library : MusicPage.songs);
      expect(tester.takeException(), isNull);
      pending.complete(
        jsonResponse({
          'tracks': [a.toJson(), b.toJson()],
        }),
      );
      await tester.pump();
      c.navigate(MusicPage.search);
      await tester.pump();
      expect(find.text(a.title), findsOneWidget);
      final playlist = Playlist(id: 'p1', name: 'My playlist', tracks: [a, b]);
      c.playlists = [playlist];
      c.openPlaylist(playlist);
      await tester.pump();
      expect(find.text('Delete playlist'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  }
}
