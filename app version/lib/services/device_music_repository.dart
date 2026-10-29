import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/music.dart';
import 'library_store.dart';
import 'music_repository.dart';
import 'youtube_catalog.dart';

class DeviceMusicRepository implements MusicRepository {
  final LibraryStore store;
  final MusicCatalog catalog;
  final Future<Directory> Function() documents;
  final Map<String, Future<String>> _downloads = {};
  DeviceMusicRepository({
    LibraryStore? store,
    MusicCatalog? catalog,
    Future<Directory> Function()? documents,
  }) : store = store ?? LibraryStore(),
       catalog = catalog ?? YoutubeCatalog(),
       documents = documents ?? getApplicationDocumentsDirectory;
  void _validate(Track track) {
    if (!RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(track.id)) {
      throw ArgumentError('Invalid song ID.');
    }
  }

  Future<Directory> _downloadDirectory() async =>
      Directory('${(await documents()).path}/downloads');
  @override
  Future<SearchPage> search(String query, int page) =>
      catalog.search(query, page);
  @override
  void cancelSearch() => catalog.cancelSearch();
  @override
  Future<String> resolveAudio(Track track) async {
    _validate(track);
    final file = File('${(await _downloadDirectory()).path}/${track.id}.m4a');
    if (await file.exists() && await file.length() > 0) {
      return file.uri.toString();
    }
    return catalog.resolveAudio(track);
  }

  @override
  Future<List<Playlist>> playlists() => store.playlists();
  @override
  Future<Playlist> createPlaylist(String name) => store.createPlaylist(name);
  @override
  Future<void> deletePlaylist(String id) => store.deletePlaylist(id);
  @override
  Future<Playlist> addTrack(String id, Track track) =>
      store.addTrack(id, track);
  @override
  Future<Playlist> removeTrack(String id, String trackId) =>
      store.removeTrack(id, trackId);
  @override
  Future<List<Track>> songs() async => (await store.songs()).take(20).toList();
  @override
  Future<List<Track>> recommend(List<Track> queue) async {
    final exclude = queue.map((t) => t.id).toSet();
    return (await store.songs())
        .where((t) => !exclude.contains(t.id))
        .take(15)
        .toList();
  }

  @override
  Future<void> score(Track track) => store.score(track);
  @override
  Future<String> download(Track track) {
    _validate(track);
    return _downloads.putIfAbsent(track.id, () async {
      try {
        return await catalog.download(track, await _downloadDirectory());
      } finally {
        _downloads.remove(track.id);
      }
    });
  }

  @override
  void dispose() => catalog.dispose();
}
