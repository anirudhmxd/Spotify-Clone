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
  }) : _cacheDirectory = cacheDirectory ?? _defaultCacheDirectory {
    _downloader = downloader ?? DataSavingDownloader();
    _streamResolver = streamResolver ?? StreamResolver(direct: _directStream);
  }
  late final StreamResolver _streamResolver;
  late final DataSavingDownloader _downloader;
  final WorkLimiter _downloadSlots = WorkLimiter(2);
  Future<void>? _preparing;

  static Future<Directory> _defaultCacheDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/spotify_app/music_cache');
  }

  final Future<Directory> Function() _cacheDirectory;
  Future<Directory>? _directoryFuture;
  @override
  Future<Directory> get cacheDir => _directoryFuture ??= _cacheDirectory();

  final Set<yt.YoutubeExplode> _clients = {};
  DateTime? _relatedUnavailableUntil;
  final Map<String, List<Track>> _related = {};
  final Map<String, Future<List<Track>>> _relatedRequests = {};
  final Map<String, Future<String>> _fileRequests = {};

  yt.YoutubeExplode? _searchClient;
  String? _query;
  final List<yt.VideoSearchList> _pages = [];
  final List<Track> _playlist = [];

  StreamIterator<Track>? _playlistIterator;
  bool _playlistEnded = false;
  bool _disposed = false;

  /// In-flight resolutions keyed by video id, so repeated selection of the
  /// same track while it is downloading reuses one download instead of
  /// starting a second one.
  final Map<String, Future<String>> _resolving = {};
  @override
  void cancelSearch() {
    if (_searchClient != null) {
      _clients.remove(_searchClient!);
      _searchClient!.close();
    }
    _searchClient = null;
    _query = null;
    _pages.clear();
    _playlist.clear();
    if (_playlistIterator != null) unawaited(_playlistIterator!.cancel());
    _playlistIterator = null;
    _playlistEnded = false;
  }

  yt.YoutubeExplode _searchClientInstance() {
    if (_disposed) throw StateError('Music catalog is closed.');
    final client = yt.YoutubeExplode();
    _clients.add(client);
    return client;
  }

  void _close(yt.YoutubeExplode client) {
    if (_clients.remove(client)) client.close();
  }

  Track _track(yt.Video video) => Track(
    id: video.id.value,
    title: video.title,
    artist: video.author,
    album: 'YouTube',
    artwork: video.thumbnails.mediumResUrl,
    durationMs: video.duration?.inMilliseconds ?? 0,
    stream: 'https://www.youtube.com/watch?v=${video.id.value}',
  );
  bool _music(yt.Video video) {
    if (video.isLive) return false;
    final seconds = video.duration?.inSeconds ?? 0;
    if (seconds > 0 && (seconds < 30 || seconds > 900)) return false;
    final title = video.title.toLowerCase();
    return ![
      'full album',
      'full concert',
      'live stream',
      'podcast',
      'interview',
      'audiobook',
      'reaction',
      'tutorial',
      'how to',
    ].any(title.contains);
  }

  static bool isPlaylist(String query) {
    final uri = Uri.tryParse(query.contains('://') ? query : 'https://$query');
    return uri != null &&
        [
          'youtube.com',
          'www.youtube.com',
          'music.youtube.com',
          'youtu.be',
        ].contains(uri.host.toLowerCase()) &&
        (uri.queryParameters['list']?.isNotEmpty ?? false);
  }

  @override
  Future<SearchPage> search(String query, int page) async {
    if (page < 0) throw ArgumentError('Page must be nonnegative.');
    if (_query != query || _searchClient == null) {
      cancelSearch();
      _query = query;
      _searchClient = _searchClientInstance();
    }
    final client = _searchClient!;
    try {
      return await (() async {
        if (isPlaylist(query)) {
          final uri = Uri.parse(
            query.contains('://') ? query : 'https://$query',
          );
          _playlistIterator ??= StreamIterator(
            client.playlists
                .getVideos(uri.queryParameters['list']!)
                .map(_track),
          );
          final iterator = _playlistIterator!;
          final offset = page * 25;
          while (_playlist.length <= offset + 25 && !_playlistEnded) {
            final available = await iterator.moveNext();
            if (!identical(client, _searchClient)) {
              throw StateError('Search cancelled.');
            }
            if (available) {
              _playlist.add(iterator.current);
            } else {
              _playlistEnded = true;
            }
          }
          return SearchPage(
            _playlist.skip(offset).take(25).toList(),
            hasMore: _playlist.length > offset + 25,
          );
        }
        if (_pages.isEmpty) {
          final first = await client.search.search(query);
          if (!identical(client, _searchClient)) {
            throw StateError('Search cancelled.');
          }
          _pages.add(first);
        }
        while (_pages.length <= page) {
          final next = await _pages.last.nextPage();
          if (!identical(client, _searchClient)) {
            throw StateError('Search cancelled.');
          }
          if (next == null || next.isEmpty) return const SearchPage([]);
          _pages.add(next);
        }
        final videos = _pages[page];
        // Keep otherwise valid short/long videos if music filtering removes the entire page.
        final filtered = videos.where(_music).toList();
        return SearchPage(
          (filtered.isEmpty ? videos : filtered).map(_track).toList(),
          hasMore: videos.isNotEmpty,
        );
      })().timeout(const Duration(seconds: 20));
    } on TimeoutException {
      if (identical(client, _searchClient)) cancelSearch();
      throw Exception('Search took too long. Please try again.');
    } on SocketException {
      throw Exception(
        'Could not connect to YouTube. Check your internet connection.',
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
    final client = _searchClientInstance();
    try {
      final manifest = await client.videos.streamsClient
          .getManifest(id, requireWatchPage: false)
          .timeout(const Duration(seconds: 5));
      return DataSavingDownloader.selectAudio(
        manifest.audioOnly,
        appleCompatible: Platform.isIOS || Platform.isMacOS,
      ).url.toString();
    } finally {
      _close(client);
    }
  }

  @override
  Future<void> prepareAudio(Track track) async {
    if (_disposed ||
        !_isVideoId(track.id) ||
        _preparing != null ||
        _fileRequests.isNotEmpty) {
      return;
    }
    final request = _prepare(track);
    _preparing = request;
    try {
      await request;
    } finally {
      _preparing = null;
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
    // A separate client keeps recommendations independent of typed searches.
    if (_relatedUnavailableUntil == null ||
        DateTime.now().isAfter(_relatedUnavailableUntil!)) {
      final client = _searchClientInstance();
      try {
        final tracks = await (() async {
          final video = await client.videos.get(seed.id);
          final related = await client.videos.getRelatedVideos(video);
          return (related ?? <yt.Video>[])
              .where(_music)
              .where((video) => video.id.value != seed.id)
              .map(_track)
              .take(25)
              .toList();
        })().timeout(const Duration(seconds: 6));
        if (tracks.isNotEmpty) return tracks;
      } catch (_) {
        // Watch-page recommendations can be rate-limited while catalog search
        // still works. Back off instead of retrying that endpoint every song.
        _relatedUnavailableUntil = DateTime.now().add(
          const Duration(minutes: 5),
        );
      } finally {
        _close(client);
      }
    }
    if (_disposed) throw StateError('Music catalog is closed.');
    final artist = seed.artist
        .replaceAll(RegExp(r'\s*-\s*Topic$|VEVO$', caseSensitive: false), '')
        .trim();
    if (artist.isEmpty || seed.id.startsWith('local_')) return [];
    final client = _searchClientInstance();
    try {
      // Discover other songs by this artist, never reuse the user's query or
      // search result queue. The repository also removes alternate editions.
      final videos = await client.search
          .search('$artist songs')
          .timeout(const Duration(seconds: 8));
      return videos
          .where(_music)
          .where((video) => video.id.value != seed.id)
          .map(_track)
          .take(25)
          .toList();
    } finally {
      _close(client);
    }
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
    _resolving.clear();
  }
}
