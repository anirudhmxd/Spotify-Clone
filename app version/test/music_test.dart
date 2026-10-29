import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_app/main.dart';
import 'package:spotify_app/models/music.dart';
import 'package:spotify_app/music_controller.dart';
import 'package:spotify_app/services/audio_engine.dart';
import 'package:spotify_app/services/music_repository.dart';

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
  stream: 'https://www.youtube.com/watch?v=aaaaaaaaaaa',
);
const b = Track(
  id: 'bbbbbbbbbbb',
  title: 'Second song',
  artist: 'Artist',
  album: 'Album',
  artwork: '',
  stream: 'https://www.youtube.com/watch?v=bbbbbbbbbbb',
);

class FakeRepository implements MusicRepository {
  Future<SearchPage> Function(String, int) onSearch = (_, _) async =>
      const SearchPage([]);
  Future<String> Function(Track) onResolve = (track) async =>
      'https://media.example/${track.id}.m4a';
  int scores = 0, cancellations = 0;
  List<Playlist> library = [];
  @override
  Future<SearchPage> search(String query, int page) => onSearch(query, page);
  @override
  void cancelSearch() {
    cancellations++;
  }

  @override
  Future<String> resolveAudio(Track track) => onResolve(track);
  @override
  Future<List<Playlist>> playlists() async => library;
  @override
  Future<Playlist> createPlaylist(String name) async {
    final playlist = Playlist(id: 'p1', name: name, tracks: []);
    library = [...library, playlist];
    return playlist;
  }

  @override
  Future<Playlist> addTrack(String id, Track track) async {
    final old = library.firstWhere((p) => p.id == id);
    final playlist = Playlist(
      id: id,
      name: old.name,
      tracks: [...old.tracks, track],
    );
    library = [playlist];
    return playlist;
  }

  @override
  Future<void> deletePlaylist(String id) async {}
  @override
  Future<Playlist> removeTrack(String id, String trackId) async =>
      library.first;
  @override
  Future<List<Track>> songs() async => [];
  @override
  Future<List<Track>> recommend(List<Track> queue) async => [b];
  @override
  Future<void> score(Track track) async {
    scores++;
  }

  @override
  Future<String> download(Track track) async => '/downloads/${track.id}.m4a';
  @override
  void dispose() {}
}

Future<void> tick() => Future<void>.delayed(Duration.zero);

void main() {
  test('clearing input invalidates in-flight direct search', () async {
    final pending = Completer<SearchPage>();
    final repository = FakeRepository()..onSearch = (_, _) => pending.future;
    final c = MusicController(repository, FakeAudio());
    c.search('old', immediate: true);
    c.search('');
    pending.complete(const SearchPage([a], hasMore: true));
    await tick();
    expect(c.searchTracks, isEmpty);
    expect(c.searching, false);
    expect(c.hasMore, false);
    expect(repository.cancellations, 2);
    c.dispose();
  });
  test(
    'new query wins even if an earlier direct request finishes later',
    () async {
      final old = Completer<SearchPage>();
      final repository = FakeRepository()
        ..onSearch = (query, _) async =>
            query == 'old' ? old.future : const SearchPage([b]);
      final c = MusicController(repository, FakeAudio());
      c.search('old', immediate: true);
      c.search('new', immediate: true);
      await tick();
      old.complete(const SearchPage([a]));
      await tick();
      expect(c.searchTracks.single.id, b.id);
      c.dispose();
    },
  );
  test('pagination failure retries the same page', () async {
    final pages = <int>[];
    final repository = FakeRepository()
      ..onSearch = (_, page) async {
        pages.add(page);
        if (pages.length == 2) throw Exception('offline');
        return SearchPage([page == 0 ? a : b], hasMore: true);
      };
    final c = MusicController(repository, FakeAudio());
    c.search('song', immediate: true);
    await tick();
    await c.loadMore();
    await c.loadMore();
    expect(pages, [0, 1, 1]);
    expect(c.searchTracks.map((t) => t.id), [a.id, b.id]);
    c.dispose();
  });
  test(
    'queue advances into local recommendations and scores each play once',
    () async {
      final repository = FakeRepository();
      final audio = FakeAudio();
      final c = MusicController(repository, audio);
      await c.playTracks([a], 0);
      await tick();
      audio.position = const Duration(seconds: 90);
      audio.positionEvents.add(audio.position);
      audio.positionEvents.add(audio.position);
      await tick();
      expect(repository.scores, 1);
      await c.next(recommend: true);
      expect(c.current?.id, b.id);
      expect(c.queueIndex, 1);
      expect(audio.loaded, 'https://media.example/${b.id}.m4a');
      c.dispose();
    },
  );
  test('outdated audio resolution cannot replace a newer song', () async {
    final old = Completer<String>();
    final repository = FakeRepository()
      ..onResolve = (track) async =>
          track.id == a.id ? old.future : 'https://media.example/b.m4a';
    final audio = FakeAudio();
    final c = MusicController(repository, audio);
    final first = c.playTracks([a, b], 0);
    await tick();
    await c.playTracks([a, b], 1);
    old.complete('https://media.example/a.m4a');
    await first;
    expect(audio.loaded, 'https://media.example/b.m4a');
    expect(c.resolvingAudio, false);
    c.dispose();
  });
  test(
    'creating a local playlist with a song preserves the pending track',
    () async {
      final c = MusicController(FakeRepository(), FakeAudio());
      await c.createPlaylist('My playlist', track: a);
      expect(c.playlists.single.tracks.single.id, a.id);
      c.dispose();
    },
  );
  testWidgets('stalled direct search times out and cancels network work', (
    tester,
  ) async {
    final pending = Completer<SearchPage>();
    final repository = FakeRepository()..onSearch = (_, _) => pending.future;
    final c = MusicController(repository, FakeAudio());
    c.search('stalled', immediate: true);
    await tester.pump(const Duration(seconds: 21));
    expect(c.searching, false);
    expect(c.searchStatus, contains('took too long'));
    expect(repository.cancellations, 2);
    pending.complete(const SearchPage([a]));
    await tester.pump();
    expect(c.searchTracks, isEmpty);
    c.dispose();
  });
  for (final width in [320.0, 800.0, 1280.0]) {
    testWidgets('search and library stay responsive at $width pixels', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final pending = Completer<SearchPage>();
      final repository = FakeRepository()..onSearch = (_, _) => pending.future;
      final c = MusicController(repository, FakeAudio());
      await tester.pumpWidget(MusicApp(controller: c));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'slow song');
      await tester.pump(const Duration(milliseconds: 350));
      expect(c.searching, true);
      await tester.tap(
        find.text(width < 800 ? 'Library' : 'Songs For You').last,
      );
      await tester.pump();
      expect(c.page, width < 800 ? MusicPage.library : MusicPage.songs);
      expect(tester.takeException(), isNull);
      pending.complete(const SearchPage([a, b]));
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
