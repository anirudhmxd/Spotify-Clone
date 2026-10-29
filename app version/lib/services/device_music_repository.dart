import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/music.dart';
import '../models/experience.dart';
import 'library_store.dart';
import 'music_repository.dart';
import 'youtube_catalog.dart';

class DeviceMusicRepository implements MusicRepository {
  final LibraryStore store;
  final MusicCatalog catalog;
  final Future<Directory> Function() documents;
  final Map<String, Future<String>> _downloads = {};
  AppSettings _settings = const AppSettings();
  DeviceMusicRepository({
    LibraryStore? store,
    MusicCatalog? catalog,
    Future<Directory> Function()? documents,
  }) : store = store ?? LibraryStore(),
       catalog = catalog ?? YoutubeCatalog(),
       documents = documents ?? getApplicationDocumentsDirectory;
  void _validate(Track track) {
    if (!RegExp(r'^(?:[A-Za-z0-9_-]{11}|local_[0-9]+)$').hasMatch(track.id)) {
      throw ArgumentError('Invalid song ID.');
    }
  }

  Future<Directory> _downloadDirectory() async =>
      Directory('${(await documents()).path}/downloads');
  @override
  Future<SearchPage> search(String query, int page) async {
    if (!_settings.offline) return catalog.search(query, page);
    final local = await profile();
    final lists = await playlists();
    final tracks = {
      for (final t in [
        ...local.liked,
        ...local.recent,
        ...local.downloads.map((r) => r.track),
        ...lists.expand((p) => p.tracks),
      ])
        t.id: t,
    };
    final matches = tracks.values
        .where(
          (t) => '${t.title} ${t.artist}'.toLowerCase().contains(
            query.toLowerCase(),
          ),
        )
        .toList();
    return SearchPage(
      matches.skip(page * 25).take(25).toList(),
      hasMore: matches.length > (page + 1) * 25,
    );
  }

  @override
  void cancelSearch() => catalog.cancelSearch();
  @override
  Future<String> resolveAudio(Track track) async {
    _validate(track);
    if (track.id.startsWith('local_')) {
      final records = (await store.profile()).downloads.where(
        (r) => r.track.id == track.id,
      );
      if (records.isEmpty || !await File(records.first.path).exists()) {
        throw StateError('This local file is no longer available.');
      }
      return File(records.first.path).uri.toString();
    }
    final file = File('${(await _downloadDirectory()).path}/${track.id}.m4a');
    if (await file.exists() && await file.length() > 0) {
      return file.uri.toString();
    }
    if (_settings.offline) {
      throw StateError('Download this song before playing in offline mode.');
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
    if (_settings.offline) {
      return Future.error(
        StateError('Turn off offline mode to download songs.'),
      );
    }
    return _downloads.putIfAbsent(track.id, () async {
      try {
        final path = await catalog.download(track, await _downloadDirectory());
        await store.saveDownload(
          DownloadRecord(
            track: track,
            path: path,
            bytes: await File(path).length(),
          ),
        );
        return path;
      } finally {
        _downloads.remove(track.id);
      }
    });
  }

  void _configureCatalog() {
    if (catalog is YoutubeCatalog) {
      (catalog as YoutubeCatalog).streamingQuality = _settings.streamingQuality;
      (catalog as YoutubeCatalog).downloadQuality = _settings.downloadQuality;
    }
  }

  @override
  Future<LibraryProfile> profile() async {
    var data = await store.profile();
    _settings = data.settings;
    _configureCatalog();
    final valid = <DownloadRecord>[];
    for (final record in data.downloads) {
      if (await File(record.path).exists()) valid.add(record);
    }
    // Adopt downloads created by earlier versions using stored track metadata.
    final candidates = {
      for (final t in [
        ...data.liked,
        ...data.recent,
        ...await store.songs(),
        ...(await store.playlists()).expand((p) => p.tracks),
      ])
        t.id: t,
    };
    for (final track in candidates.values) {
      if (valid.any((r) => r.track.id == track.id) ||
          track.id.startsWith('local_')) {
        continue;
      }
      _validate(track);
      final file = File('${(await _downloadDirectory()).path}/${track.id}.m4a');
      if (await file.exists() && await file.length() > 0) {
        final record = DownloadRecord(
          track: track,
          path: file.path,
          bytes: await file.length(),
        );
        await store.saveDownload(record);
        valid.add(record);
      }
    }
    return data.withDownloads(valid);
  }

  @override
  Future<void> saveSettings(AppSettings settings) async {
    await store.saveSettings(settings);
    _settings = settings;
    _configureCatalog();
    if (settings.offline) cancelSearch();
  }

  @override
  Future<void> setLiked(Track track, bool liked) =>
      store.setLiked(track, liked);
  @override
  Future<void> rememberSearch(String term) => store.rememberSearch(term);
  @override
  Future<void> recordListening(
    Track track,
    int milliseconds,
    DateTime at,
    bool newPlay,
  ) => store.recordListening(track, milliseconds, at, newPlay);
  @override
  Future<Playlist> editPlaylist(Playlist playlist) =>
      store.editPlaylist(playlist);
  @override
  Future<void> removeDownload(String id) async {
    if (_downloads.containsKey(id)) {
      throw StateError('Wait for the download to finish.');
    }
    final matches = (await store.profile()).downloads.where(
      (r) => r.track.id == id,
    );
    if (matches.isNotEmpty) {
      final file = File(matches.first.path);
      if (await file.exists()) await file.delete();
    }
    await store.removeDownload(id);
  }

  @override
  Future<Track> importAudio(String path, String name) async {
    final extension = name.split('.').last.toLowerCase();
    if (![
      'mp3',
      'm4a',
      'aac',
      'wav',
      'flac',
      'ogg',
      'opus',
    ].contains(extension)) {
      throw ArgumentError('Choose an audio file.');
    }
    final dir = Directory('${(await documents()).path}/imports');
    await dir.create(recursive: true);
    final id = 'local_${DateTime.now().microsecondsSinceEpoch}';
    final file = await File(path).copy('${dir.path}/$id.$extension');
    final track = Track(
      id: id,
      title: name.replaceFirst(RegExp(r'\.[^.]+$'), ''),
      artist: 'Local files',
      album: 'On this device',
      artwork: '',
      stream: file.uri.toString(),
    );
    await store.saveDownload(
      DownloadRecord(track: track, path: file.path, bytes: await file.length()),
    );
    return track;
  }

  @override
  Future<void> clearHistory() => store.clearHistory();
  @override
  Future<String> exportLibrary() => store.exportLibrary();
  @override
  Future<void> importLibrary(String text) => store.importLibrary(text);
  @override
  void dispose() => catalog.dispose();
}
