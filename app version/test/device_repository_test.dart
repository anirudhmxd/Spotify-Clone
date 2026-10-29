import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_app/models/music.dart';
import 'package:spotify_app/services/device_music_repository.dart';
import 'package:spotify_app/services/library_store.dart';
import 'package:spotify_app/services/music_repository.dart';
import 'package:spotify_app/services/youtube_catalog.dart';

const song = Track(
  id: 'aaaaaaaaaaa',
  title: 'Song',
  artist: 'Artist',
  album: 'Album',
  artwork: '',
  stream: 'https://www.youtube.com/watch?v=aaaaaaaaaaa',
);
const other = Track(
  id: 'bbbbbbbbbbb',
  title: 'Other',
  artist: 'Artist',
  album: 'Album',
  artwork: '',
  stream: 'https://www.youtube.com/watch?v=bbbbbbbbbbb',
);

class FakeCatalog implements MusicCatalog {
  int resolutions = 0, downloads = 0;
  @override
  Future<SearchPage> search(String query, int page) async =>
      const SearchPage([song]);
  @override
  void cancelSearch() {}
  @override
  Future<String> resolveAudio(Track track) async {
    resolutions++;
    return 'https://media.example/audio.m4a';
  }

  @override
  Future<String> download(Track track, Directory directory) async {
    downloads++;
    await directory.create(recursive: true);
    final file = File('${directory.path}/${track.id}.m4a');
    await file.writeAsBytes([1, 2, 3]);
    return file.path;
  }

  @override
  void dispose() {}
}

void main() {
  late Directory directory;
  late LibraryStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('spotify-device-test-');
    store = LibraryStore(directory: () async => directory);
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test(
    'playlists survive reopening, deduplicate, remove songs and delete locally',
    () async {
      final playlist = await store.createPlaylist('  My playlist  ');
      await store.addTrack(playlist.id, song);
      await store.addTrack(playlist.id, song);
      final reopened = LibraryStore(directory: () async => directory);
      var saved = (await reopened.playlists()).single;
      expect(saved.name, 'My playlist');
      expect(saved.tracks.single.id, song.id);
      saved = await reopened.removeTrack(playlist.id, song.id);
      expect(saved.tracks, isEmpty);
      await reopened.deletePlaylist(playlist.id);
      expect(await reopened.playlists(), isEmpty);
    },
  );
  test(
    'concurrent listening updates serialize without losing counts',
    () async {
      await Future.wait(List.generate(20, (_) => store.score(song)));
      await store.score(other);
      final songs = await LibraryStore(
        directory: () async => directory,
      ).songs();
      expect(songs.first.id, song.id);
      expect(songs.first.fullPlays, 20);
      expect(songs.last.fullPlays, 1);
    },
  );
  test('failed edits leave the library usable', () async {
    await expectLater(store.createPlaylist('  '), throwsArgumentError);
    final playlist = await store.createPlaylist('Valid');
    expect((await store.playlists()).single.id, playlist.id);
  });
  test('damaged library restores its last good backup', () async {
    final playlist = await store.createPlaylist('Saved');
    await store.addTrack(playlist.id, song);
    await store.playlists();
    await File('${directory.path}/music_library.json').writeAsString('{broken');
    final restored = await store.playlists();
    expect(restored.single.tracks.single.id, song.id);
  });
  test('local recommendations exclude the current queue', () async {
    await store.score(song);
    await store.score(other);
    final repository = DeviceMusicRepository(
      store: store,
      catalog: FakeCatalog(),
      documents: () async => directory,
    );
    final recommendations = await repository.recommend([song]);
    expect(recommendations.single.id, other.id);
    repository.dispose();
  });
  test(
    'downloaded audio plays from device storage without network resolution',
    () async {
      final catalog = FakeCatalog();
      final repository = DeviceMusicRepository(
        store: store,
        catalog: catalog,
        documents: () async => directory,
      );
      final paths = await Future.wait([
        repository.download(song),
        repository.download(song),
      ]);
      expect(paths[0], paths[1]);
      expect(catalog.downloads, 1);
      final source = await repository.resolveAudio(song);
      expect(Uri.parse(source).scheme, 'file');
      expect(catalog.resolutions, 0);
      expect(await File.fromUri(Uri.parse(source)).readAsBytes(), [1, 2, 3]);
      repository.dispose();
    },
  );
  test('playlist detection accepts YouTube URLs only', () {
    expect(
      YoutubeCatalog.isPlaylist(
        'https://www.youtube.com/playlist?list=PLexample',
      ),
      true,
    );
    expect(
      YoutubeCatalog.isPlaylist(
        'music.youtube.com/watch?v=aaaaaaaaaaa&list=PLexample',
      ),
      true,
    );
    expect(
      YoutubeCatalog.isPlaylist('https://example.com/playlist?list=PLexample'),
      false,
    );
    expect(YoutubeCatalog.isPlaylist('a song name'), false);
  });
}
