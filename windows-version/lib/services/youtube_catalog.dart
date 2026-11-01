import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;
import '../models/music.dart';
import 'music_repository.dart';
import 'stream_resolver.dart';
import 'data_saving_downloader.dart';
import 'work_limiter.dart';
import 'audio_diagnostics.dart';
import 'music_songs_client.dart';

abstract class MusicCatalog {
  Future<SearchPage> search(String query, int page);
  void cancelSearch();

  /// Resolves a track to a stream URL or a playable local audio file path.
  /// When [offline] is true and nothing is cached, throws without downloading.
  Future<String> resolveAudio(
    Track track, {
    bool offline = false,
    bool preferDownload = false,
    bool refreshStream = false,
  });
  Future<void> prepareAudio(Track track);
  Future<List<Track>> related(Track seed);
  Future<String> download(Track track, Directory directory);

  /// Directory used to cache resolved audio (shared by resolveAudio/download).
  Future<Directory> get cacheDir;
  void dispose();
}

/// Stream when available; save low-bitrate audio directly with YoutubeExplode.
class YoutubeCatalog implements MusicCatalog {
  YoutubeCatalog({
    Future<Directory> Function()? cacheDirectory,
    StreamResolver? streamResolver,
    DataSavingDownloader? downloader,
    yt.YoutubeExplode Function()? audioClientFactory,
    MusicSongsClient Function()? musicClientFactory,
  }) : _cacheDirectory = cacheDirectory ?? _defaultCacheDirectory,
       _audioClientFactory = audioClientFactory ?? yt.YoutubeExplode.new,
       _musicClientFactory = musicClientFactory ?? MusicSongsClient.new {
    _downloader = downloader ?? DataSavingDownloader();
    _streamResolver = streamResolver ?? StreamResolver(direct: _directStream);
  }
  final yt.YoutubeExplode Function() _audioClientFactory;
  late final StreamResolver _streamResolver;
  late final DataSavingDownloader _downloader;
  final WorkLimiter _downloadSlots = WorkLimiter(2);
  final _preparing = <String, Future<void>>{};
  yt.YoutubeExplode? _audioClient;

  static Future<Directory> _defaultCacheDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/spotify_app/music_cache');
  }

  final Future<Directory> Function() _cacheDirectory;
  Future<Directory>? _directoryFuture;
  @override
  Future<Directory> get cacheDir => _directoryFuture ??= _cacheDirectory();

  final Set<yt.YoutubeExplode> _clients = {};
  final MusicSongsClient Function() _musicClientFactory;
  MusicSongsClient? _musicClient;
  MusicSongsClient get _music => _musicClient ??= _musicClientFactory();
  final Map<String, List<Track>> _related = {};
  final Map<String, Future<List<Track>>> _relatedRequests = {};
  final Map<String, Future<String>> _fileRequests = {};

  MusicSongsClient? _searchClient;
  String? _query;
  final List<SongPage> _pages = [];

  bool _disposed = false;

  /// In-flight resolutions keyed by video id, so repeated selection of the
  /// same track while it is downloading reuses one download instead of
  /// starting a second one.
  final Map<String, Future<String>> _resolving = {};
  @override
  void cancelSearch() {
    _searchClient?.close();
    _searchClient = null;
    _query = null;
    _pages.clear();
  }

  void _close(yt.YoutubeExplode client) {
    if (_clients.remove(client)) client.close();
  }

  @override
  Future<SearchPage> search(String query, int page) async {
    if (_disposed) throw StateError('Music catalog is closed.');
    if (page < 0) throw ArgumentError('Page must be nonnegative.');
    final uri = Uri.tryParse(query.contains('://') ? query : 'https://$query');
    if (uri != null &&
        [
          'youtube.com',
          'www.youtube.com',
          'music.youtube.com',
          'youtu.be',
        ].contains(uri.host.toLowerCase()) &&
        (uri.queryParameters.containsKey('list') ||
            uri.path == '/watch' ||
            uri.host == 'youtu.be')) {
      throw ArgumentError(
        'Search for a song or artist name instead of a video or playlist link.',
      );
    }
    if (_query != query || _searchClient == null) {
      cancelSearch();
      _query = query;
      _searchClient = _musicClientFactory();
    }
    final client = _searchClient!;
    try {
      return await (() async {
        if (_pages.isEmpty) {
          final first = await client.search(query);
          if (!identical(client, _searchClient)) {
            throw StateError('Search cancelled.');
          }
          _pages.add(first);
        }
        while (_pages.length <= page) {
          final token = _pages.last.continuation;
          if (token == null) return const SearchPage([]);
          final next = await client.search(query, continuation: token);
          if (!identical(client, _searchClient)) {
            throw StateError('Search cancelled.');
          }
          _pages.add(next);
        }
        final result = _pages[page];
        return SearchPage(
          result.tracks.where((t) => t.isSong).toList(),
          hasMore: result.continuation != null,
        );
      })().timeout(const Duration(seconds: 20));
    } on TimeoutException {
      if (identical(client, _searchClient)) cancelSearch();
      throw Exception('Search took too long. Please try again.');
    } on SocketException {
      throw Exception(
        'Could not connect to the music catalog. Check your internet connection.',
      );
    }
  }

  Future<void> _requireSong(Track track, {bool offline = false}) async {
    if (track.isSong) return;
    if (offline) {
      throw StateError(
        'Find this older item in song search once before playing it offline.',
      );
    }
    if (!await _music.isSong(track.id)) {
      throw StateError(
        'This item is a video, not a song. Choose its song version from search.',
      );
    }
  }

  /// Magic bytes for an EBML/Matroska/WebM container.
  /// Used to detect Opus/WebM payloads that previous builds renamed to `.m4a`
  /// (which AVFoundation on Apple platforms refuses to open with -11829).
  static final List<int> _webmMagic = [0x1A, 0x45, 0xDF, 0xA3];

  /// Returns true if [header] (file's first bytes) is a WebM/Matroska stream.
  static bool _isWebM(List<int> header) =>
      header.length >= 4 &&
      header[0] == _webmMagic[0] &&
      header[1] == _webmMagic[1] &&
      header[2] == _webmMagic[2] &&
      header[3] == _webmMagic[3];

  /// Returns a non-empty cached file for [videoId] inside [dir], if any.
  /// Checks known final audio filenames directly, without scanning the library.
  /// Self-heals corrupted legacy caches: on iOS/macOS, if a cached file's
  /// actual content is WebM/Opus (which AVFoundation cannot play), it is
  /// deleted so a fresh, properly-formatted download can replace it.
  static Future<File?> cachedFile(Directory dir, String videoId) async {
    if (!await dir.exists()) return null;
    try {
      for (final extension in ['m4a', 'mp3', 'aac', 'webm', 'opus', 'ogg']) {
        final name = '$videoId.$extension';
        final entity = File('${dir.path}/$name');
        if (!await entity.exists() || await entity.length() == 0) {
          continue;
        }
        // On Apple platforms, AVFoundation can only play m4a/mp3/wav/etc.
        // A cached file whose bytes are actually WebM/Opus is unplayable and
        // would surface as `OSStatus -11829`. Detect & purge it so the next
        // call re-downloads in the correct format.
        if (Platform.isIOS || Platform.isMacOS) {
          final List<int> header;
          try {
            header = await entity.openRead(0, 4).first;
          } catch (_) {
            continue;
          }
          if (_isWebM(header)) {
            try {
              await entity.delete();
              debugPrint(
                'youtube_catalog: dropped unplayable WebM cache $name '
                '(AVFoundation cannot open it). It will be re-downloaded.',
              );
            } catch (_) {}
            continue;
          }
        }
        return entity;
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  static bool _isVideoId(String id) =>
      RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id);

  @override
  Future<String> resolveAudio(
    Track track, {
    bool offline = false,
    bool preferDownload = false,
    bool refreshStream = false,
  }) async {
    if (_disposed) throw StateError('Music catalog is closed.');
    if (!_isVideoId(track.id)) throw ArgumentError('Invalid song ID.');
    await _requireSong(track, offline: offline);
    final dir = await cacheDir;
    final cached = await cachedFile(dir, track.id);
    if (cached != null) return cached.path;
    if (offline) {
      throw StateError('Download this song before playing in offline mode.');
    }
    if (preferDownload) return download(track, dir);
    // The player rejected its URL. Use the library's byte-stream API to save
    // a fresh audio-only response instead of retrying that same playback URL.
    if (refreshStream) return download(track, dir);
    final pending = _resolving[track.id];
    if (pending != null) return pending;
    final request = _resolveOnline(track, dir);
    _resolving[track.id] = request;
    try {
      return await request;
    } finally {
      _resolving.remove(track.id);
    }
  }

  Future<String> _resolveOnline(
    Track track,
    Directory dir, {
    bool refresh = false,
  }) async {
    try {
      return await _streamResolver.resolve(track.id, refresh: refresh);
    } catch (_) {
      if (_disposed) throw StateError('Music catalog is closed.');
      return download(track, dir);
    }
  }

  Future<String?> _directStream(String id) async {
    // Reuse the visitor session and warm HTTP connections across audio lookups.
    var client = _audioClient;
    if (client == null) {
      client = _audioClientFactory();
      _clients.add(client);
      _audioClient = client;
    }
    try {
      final manifest = await client.videos.streamsClient
          .getManifest(
            id,
            requireWatchPage: false,
            audioOnly: true,
            validateStreams: false,
          )
          .timeout(const Duration(seconds: 5));
      return DataSavingDownloader.selectAudio(
        manifest.audioOnly,
        appleCompatible: Platform.isIOS || Platform.isMacOS,
      ).url.toString();
    } catch (_) {
      // A timed-out connection must not poison subsequent audio lookups.
      if (identical(_audioClient, client)) _audioClient = null;
      _close(client);
      rethrow;
    }
  }

  @override
  Future<void> prepareAudio(Track track) async {
    if (_disposed ||
        !track.isSong ||
        !_isVideoId(track.id) ||
        _fileRequests.isNotEmpty) {
      return;
    }
    final pending = _preparing[track.id];
    if (pending != null) return pending;
    if (_preparing.length >= 2) return;
    final request = _prepare(track);
    _preparing[track.id] = request;
    try {
      await request;
    } finally {
      _preparing.remove(track.id);
    }
  }

  Future<void> _prepare(Track track) async {
    try {
      if (await cachedFile(await cacheDir, track.id) != null || _disposed) {
        return;
      }
      await _streamResolver.resolve(track.id);
    } catch (_) {
      // Preparation is opportunistic; never start a full download or show an error.
    }
  }

  @override
  Future<List<Track>> related(Track seed) async {
    if (_disposed) throw StateError('Music catalog is closed.');
    if (!_isVideoId(seed.id)) return [];
    final cached = _related[seed.id];
    if (cached != null) return cached;
    final pending = _relatedRequests[seed.id];
    if (pending != null) return pending;
    final request = _fetchRelated(seed);
    _relatedRequests[seed.id] = request;
    try {
      final tracks = await request;
      if (tracks.isNotEmpty) {
        if (_related.length >= 20) _related.remove(_related.keys.first);
        _related[seed.id] = tracks;
      }
      return tracks;
    } finally {
      _relatedRequests.remove(seed.id);
    }
  }

  Future<List<Track>> _fetchRelated(Track seed) async {
    var tracks = <Track>[];
    try {
      tracks = await _music.related(seed.id);
    } catch (_) {
      // Song search remains a typed fallback if the radio endpoint is unavailable.
    }
    if (tracks.isNotEmpty) return tracks.where((t) => t.isSong).toList();
    if (_disposed || seed.artist.isEmpty || seed.id.startsWith('local_')) {
      return [];
    }
    final page = await _music.search(seed.artist);
    return page.tracks
        .where((t) => t.isSong && t.id != seed.id)
        .take(25)
        .toList();
  }

  @override
  Future<String> download(Track track, Directory directory) {
    if (_disposed) return Future.error(StateError('Music catalog is closed.'));
    if (!_isVideoId(track.id)) {
      return Future.error(ArgumentError('Invalid song ID.'));
    }
    final key = '${directory.path}/${track.id}';
    final pending = _fileRequests[key];
    if (pending != null) return pending;
    // Register before any disk await: a completed cache check must not race
    // another caller's download finishing and removing its in-flight entry.
    final request = _downloadToDirectory(track, directory);
    _fileRequests[key] = request;
    return request.whenComplete(() {
      _fileRequests.remove(key);
    });
  }

  Future<String> _downloadToDirectory(Track track, Directory directory) async {
    await _requireSong(track);
    await directory.create(recursive: true);
    final cached = await cachedFile(directory, track.id);
    if (cached != null) return cached.path;
    final queued = Stopwatch()..start();
    AudioDiagnostics.log('download.queued', 'track=${track.id}');
    final request = _downloadSlots.run(() async {
      AudioDiagnostics.log(
        'download.start',
        'track=${track.id} queue_ms=${queued.elapsedMilliseconds}',
      );
      if (_disposed) throw StateError('Music catalog is closed.');
      final file = await _downloader.downloadSmallestAudio(
        track.id,
        directory: directory,
      );
      return file.path;
    });
    return request;
  }

  @override
  void dispose() {
    cancelSearch();
    _disposed = true;
    _streamResolver.dispose();
    _downloader.dispose();
    for (final client in _clients.toList()) {
      _close(client);
    }
    _searchClient = null;
    _audioClient = null;
    _musicClient?.close();
    _resolving.clear();
  }
}
