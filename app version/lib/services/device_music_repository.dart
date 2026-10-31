import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/music.dart';
import '../models/experience.dart';
import 'library_store.dart';
import 'music_repository.dart';
import 'youtube_catalog.dart';
import 'youtube_importer.dart';

class DeviceMusicRepository implements MusicRepository {
  final YoutubeImporter youtubeImporter;
  final LibraryStore store;
  final MusicCatalog catalog;
  final Future<Directory> Function() documents;
  final Map<String, Future<String>> _downloads = {};
  final Set<String> _verifiedLegacySongs = {};
  bool _adoptedLegacyDownloads = false;
  AppSettings _settings = const AppSettings();
  DeviceMusicRepository({
    LibraryStore? store,
    YoutubeImporter? youtubeImporter,
    MusicCatalog? catalog,
    Future<Directory> Function()? documents,
  }) : youtubeImporter = youtubeImporter ?? YoutubeImporter(),
       store = store ?? LibraryStore(),
       catalog = catalog ?? YoutubeCatalog(),
       documents = documents ?? getApplicationDocumentsDirectory;
  void _validate(Track track) {
    if (!RegExp(r'^(?:[A-Za-z0-9_-]{11}|local_[0-9]+)$').hasMatch(track.id)) {
      throw ArgumentError('Invalid song ID.');
    }
  }

  Track _classified(Track track) =>
      !track.isSong && _verifiedLegacySongs.contains(track.id)
      ? Track.fromJson({...track.toJson(), 'isMusic': true})
      : track;

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
        .where((t) => t.isSong)
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
  Future<String> resolveAudio(
    Track track, {
    bool preferDownload = false,
    bool refreshStream = false,
  }) async {
    _validate(track);
    track = _classified(track);
    if (track.id.startsWith('local_')) {
      final records = (await store.profile()).downloads.where(
        (r) => r.track.id == track.id,
      );
      if (records.isEmpty || !await File(records.first.path).exists()) {
        throw StateError('This local file is no longer available.');
      }
      return File(records.first.path).uri.toString();
    }
    final source = await catalog.resolveAudio(
      track,
      offline: _settings.offline,
      preferDownload: preferDownload,
      refreshStream: refreshStream,
    );
    if (!track.isSong && !_settings.offline) {
      _verifiedLegacySongs.add(track.id);
      // Resolution verifies old remote items before using even a cached file.
      await store.confirmMusic(track.id);
    }
    final uri = Uri.tryParse(source);
    return uri != null &&
            (uri.scheme == 'https' ||
                uri.scheme == 'http' ||
                uri.scheme == 'file')
        ? source
        : File(source).uri.toString();
  }

  @override
  Future<void> prepareAudio(Track track) async {
    if (_settings.offline || track.id.startsWith('local_')) return;
    await catalog.prepareAudio(track);
  }

  Future<Directory> _cacheDirectory() => catalog.cacheDir;

  @override
  Future<List<Playlist>> playlists() => store.playlists();
  @override
  Future<Playlist> createPlaylist(String name) => store.createPlaylist(name);
  @override
  Future<Playlist> blendPlaylists(String name, List<String> playlistIds) =>
      store.blendPlaylists(name, playlistIds);
  @override
  Future<void> deletePlaylist(String id) => store.deletePlaylist(id);
  @override
  Future<Playlist> addTrack(String id, Track track) =>
      store.addTrack(id, track);
  @override
  Future<Playlist> removeTrack(String id, String trackId) =>
      store.removeTrack(id, trackId);
  @override
  Future<List<Track>> songs() async =>
      (await store.songs()).where((t) => t.isSong).take(20).toList();
  @override
  Future<List<Track>> recommend(List<Track> queue) async {
    final profile = await store.profile();
    final seeds = queue.isNotEmpty
        ? queue.reversed.take(2).toList()
        : [
            ...profile.recent,
            ...profile.liked,
          ].where((t) => t.isSong).take(2).toList();
    if (seeds.isEmpty) return [];
    final exclude = {...queue.map((t) => t.id), ...seeds.map((t) => t.id)};
    final titles = {...queue.map(_songKey), ...seeds.map(_songKey)};
    final candidates = <Track>[];
    if (!_settings.offline) {
      final batches = await Future.wait(
        seeds.map((seed) async {
          try {
            return await catalog.related(seed);
          } catch (_) {
            return <Track>[];
          }
        }),
      );
      // Interleave seeds so a single artist does not fill the whole station.
      for (var i = 0; i < 25; i++) {
        for (final batch in batches) {
          if (i < batch.length) candidates.add(batch[i]);
        }
      }
    }
    final artists = seeds.map((t) => t.artist.toLowerCase()).toSet();
    final downloaded = profile.downloads.map((r) => r.track.id).toSet();
    candidates.addAll(
      [
        ...profile.liked,
        ...profile.recent,
        ...await store.songs(),
        ...profile.downloads.map((r) => r.track),
      ].where(
        (t) =>
            artists.contains(t.artist.toLowerCase()) &&
            (!_settings.offline || downloaded.contains(t.id)),
      ),
    );
    final result = <Track>[];
    for (final track in candidates) {
      if (!track.isSong ||
          exclude.contains(track.id) ||
          titles.contains(_songKey(track))) {
        continue;
      }
      exclude.add(track.id);
      titles.add(_songKey(track));
      result.add(track);
      if (result.length == 15) break;
    }
    return result;
  }

  static String _songKey(Track track) => track.title
      .toLowerCase()
      .replaceAll(RegExp(r'\([^)]*\)|\[[^\]]*\]'), '')
      .replaceAll(
        RegExp(r'official|music video|lyric video|lyrics|audio|video'),
        '',
      )
      .replaceAll(RegExp(r'[^a-z0-9\u0080-\uffff]'), '');

  @override
  Future<void> score(Track track) => store.score(_classified(track));
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
        final path = await catalog.download(track, await _cacheDirectory());
        if (!track.isSong) {
          _verifiedLegacySongs.add(track.id);
          await store.confirmMusic(track.id);
        }
        await store.saveDownload(
          DownloadRecord(
            track: _classified(track),
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

  @override
  Future<LibraryProfile> profile() async {
    var data = await store.profile();
    _settings = data.settings;
    final valid = <DownloadRecord>[];
    for (final record in data.downloads) {
      if (await File(record.path).exists()) valid.add(record);
    }
    // Adopt legacy downloads once, not on every like or navigation.
    if (!_adoptedLegacyDownloads) {
      final candidates = {
        for (final t in [
          ...data.liked,
          ...data.recent,
          ...await store.songs(),
          ...(await store.playlists()).expand((p) => p.tracks),
        ])
          t.id: t,
      };
      final cacheDir = await _cacheDirectory();
      for (final track in candidates.values) {
        if (valid.any((r) => r.track.id == track.id) ||
            track.id.startsWith('local_')) {
          continue;
        }
        _validate(track);
        final cached = await YoutubeCatalog.cachedFile(cacheDir, track.id);
        if (cached != null) {
          final record = DownloadRecord(
            track: track,
            path: cached.path,
            bytes: await cached.length(),
          );
          await store.saveDownload(record);
          valid.add(record);
        }
      }
      _adoptedLegacyDownloads = true;
    }
    return data.withDownloads(valid);
  }

  @override
  Future<Map<String, dynamic>?> loadPlaybackState() =>
      store.playbackState();

  @override
  Future<void> savePlaybackState(Map<String, dynamic> state) =>
      store.savePlaybackState(state);

  @override
  Future<void> saveSettings(AppSettings settings) async {
    await store.saveSettings(settings);
    _settings = settings;
    if (settings.offline) cancelSearch();
  }

  @override
  Future<void> setLiked(Track track, bool liked) =>
      store.setLiked(_classified(track), liked);
  @override
  Future<void> rememberSearch(String term) => store.rememberSearch(term);
  @override
  Future<void> recordListening(
    Track track,
    int milliseconds,
    DateTime at,
    bool newPlay,
  ) => store.recordListening(_classified(track), milliseconds, at, newPlay);
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
  Future<Track> importYoutube(String url) async {
    if (_settings.offline) {
      throw StateError('Turn off offline mode to import from YouTube.');
    }
    final id = YoutubeImporter.localId(YoutubeImporter.videoId(url));
    for (final record in (await store.profile()).downloads) {
      if (record.track.id == id && await File(record.path).exists()) {
        return record.track;
      }
    }
    final record = await youtubeImporter.import(
      url,
      Directory('${(await documents()).path}/imports'),
    );
    await store.saveDownload(record);
    return record.track;
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
