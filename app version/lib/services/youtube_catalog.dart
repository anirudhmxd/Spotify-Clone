import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;
import 'package:ytdlp_flutter/ytdlp_flutter.dart';
import '../models/music.dart';
import 'music_repository.dart';
import 'stream_resolver.dart';
import 'audio_file_downloader.dart';
import 'work_limiter.dart';
import 'audio_diagnostics.dart';

/// YouTube watch URL prefix used for both resolution and downloads.
const String _youtubeWatchUrl = 'https://www.youtube.com/watch?v=';

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

/// Stream first for fast starts; retain native-container downloads as a fallback.
class YoutubeCatalog implements MusicCatalog {
  YoutubeCatalog({
    Future<Directory> Function()? cacheDirectory,
    StreamResolver? streamResolver,
    AudioFileDownloader? fileDownloader,
  }) : _cacheDirectory = cacheDirectory ?? _defaultCacheDirectory {
    _fileDownloader = fileDownloader ?? AudioFileDownloader();
    _streamResolver =
        streamResolver ??
        StreamResolver(
          direct: _directStream,
          native: Platform.isAndroid ? _nativeStream : null,
        );
  }
  late final StreamResolver _streamResolver;
  late final AudioFileDownloader _fileDownloader;
  final Set<String> _rejectedPlayback = {};
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
  bool _ytDlpReady = false;
  Future<void>? _ytDlpInitFuture;

  /// Starts the embedded yt-dlp engine once (idempotent in the plugin).
  Future<void> _ensureYtdlp() {
    if (_ytDlpReady) {
      return Future<void>.value();
    }

    return _ytDlpInitFuture ??= _initializeYtdlp();
  }

  Future<void> _initializeYtdlp() async {
    final timer = Stopwatch()..start();
    AudioDiagnostics.log('engine.start', 'initializing native runtime');
    try {
      debugPrint('[YTDLP] Initialising native engine...');

      await Ytdlp.init().timeout(const Duration(minutes: 2));

      _ytDlpReady = true;
      debugPrint('[YTDLP] Engine initialised successfully.');
      AudioDiagnostics.log('engine.ready', 'ms=${timer.elapsedMilliseconds}');
    } catch (e) {
      AudioDiagnostics.log('engine.failed', e);
      rethrow;
    } finally {
      _ytDlpInitFuture = null;
    }
  }

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

  /// Format selector that grabs a single pre-muxed audio stream **without**
  /// invoking FFmpeg.
  ///
  /// Order of preference:
  ///   1. `bestaudio[ext=m4a]` — AAC in an M4A container. Plays natively on
  ///      macOS, iOS, Android, and Windows. This is what YouTube serves for
  ///      ~every music video, so it is almost always picked.
  ///   2. `bestaudio[ext=mp3]` — rare on YouTube, but universally playable.
  ///   3. `bestaudio` — last resort (Opus/WebM). On iOS/macOS this file will
  ///      fail to play; the `cachedFile` guard will purge it next time so
  ///      the user gets a clean re-download instead of a stuck broken cache.
  ///
  /// We deliberately do NOT pass `audioFormat` to [Ytdlp.downloadAudio]:
  /// that flag triggers FFmpeg transcoding, which (a) is slow, (b) only
  /// works on Android (FFmpeg is not bundled on iOS/macOS), and (c) when
  /// the conversion half-works it produces a file AVFoundation rejects with
  /// `OSStatus -11829`.
  static const String _audioFormat =
      'bestaudio[ext=m4a]/bestaudio[ext=mp3]/bestaudio';

  /// Downloads the audio of [url] into [dir] and returns the finished
  /// file's path. The file is kept in whatever native container yt-dlp
  /// chose — no FFmpeg, no extension renaming — so AVFoundation sees a
  /// file whose bytes and extension actually agree.
  Future<String> _fetchAudio(String url, Track track, Directory dir) async {
    debugPrint('[YTDLP] Starting download: ${track.title}');
    debugPrint('[YTDLP] Video ID: ${track.id}');

    try {
      debugPrint('[YTDLP] Initialising engine...');
      await _ensureYtdlp();
      debugPrint('[YTDLP] Engine ready.');

      await dir.create(recursive: true);

      debugPrint('[YTDLP] Downloading audio...');

      final stopwatch = Stopwatch()..start();
      var lastProgress = -2000;
      AudioDiagnostics.log('native.start', 'track=${track.id}');

      final path = await Ytdlp.downloadAudio(
        url: url,
        outputDir: dir.path,
        taskId: track.id,
        format: _audioFormat,
        onProgress: AudioDiagnostics.enabled
            ? (progress) {
                final elapsed = stopwatch.elapsedMilliseconds;
                if (elapsed - lastProgress < 2000) return;
                lastProgress = elapsed;
                AudioDiagnostics.log(
                  'native.progress',
                  'track=${track.id} ms=$elapsed $progress',
                );
              }
            : null,
      ).timeout(const Duration(minutes: 3));

      stopwatch.stop();

      AudioDiagnostics.log(
        'native.complete',
        'track=${track.id} ms=${stopwatch.elapsedMilliseconds}',
      );
      debugPrint('[YTDLP] Download completed in ${stopwatch.elapsed}');
      debugPrint('[YTDLP] Returned path: $path');

      final file = File(path);

      if (!await file.exists()) {
        throw Exception('Downloaded audio file is missing.');
      }

      final bytes = await file.length();

      if (bytes == 0) {
        throw Exception('Downloaded audio file is empty.');
      }

      final currentName = file.uri.pathSegments.last;
      final ext = currentName.contains('.')
          ? currentName.split('.').last
          : 'm4a';

      final expectedPath = '${dir.path}/${track.id}.$ext';

      if (file.path != expectedPath) {
        final existing = File(expectedPath);

        if (await existing.exists()) {
          await existing.delete();
        }

        await file.rename(expectedPath);
        debugPrint('[YTDLP] Renamed file: $expectedPath');
      }

      debugPrint('[YTDLP] SUCCESS: $bytes bytes downloaded.');

      return expectedPath;
    } on TimeoutException {
      try {
        await Ytdlp.cancel(track.id).timeout(const Duration(seconds: 2));
      } catch (_) {}
      debugPrint('[YTDLP] ERROR: Download timed out.');
      throw Exception('Download timed out. Please try again.');
    } catch (e) {
      AudioDiagnostics.log('native.failed', 'track=${track.id} error=$e');
      rethrow;
    }
  }

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
    if (refreshStream) {
      // The player has already rejected this source. Do not feed its URL back
      // to the file downloader when no native metadata resolver is available.
      if (_rejectedPlayback.length >= 100) {
        _rejectedPlayback.remove(_rejectedPlayback.first);
      }
      _rejectedPlayback.add(track.id);
      if (_streamResolver.native == null) return download(track, dir);
      return _resolveOnline(track, dir, refresh: true);
    }
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
      final streams =
          manifest.audioOnly
              .where((stream) => stream.container.name == 'mp4')
              .toList()
            ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
      return streams.isEmpty ? null : streams.first.url.toString();
    } finally {
      _close(client);
    }
  }

  Future<String?> _nativeStream(String id) async {
    await _ensureYtdlp();
    if (_disposed) return null;
    return Ytdlp.resolveAudio('$_youtubeWatchUrl$id');
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
      if (_rejectedPlayback.contains(track.id)) {
        AudioDiagnostics.log(
          'download.native_after_rejection',
          'track=${track.id}',
        );
        return _fetchAudio('$_youtubeWatchUrl${track.id}', track, directory);
      }
      try {
        // Reuse the resolved/prefetched stream and its in-flight extraction.
        final url = await _streamResolver.resolve(track.id);
        if (_disposed) throw StateError('Music catalog is closed.');
        return await _fileDownloader.download(
          url,
          File('${directory.path}/${track.id}.m4a'),
        );
      } catch (error) {
        AudioDiagnostics.log(
          'download.fallback',
          'track=${track.id} error=$error',
        );
        if (_disposed) throw StateError('Music catalog is closed.');
        // Signed links can expire or reject range access. Keep the native path.
        return _fetchAudio('$_youtubeWatchUrl${track.id}', track, directory);
      }
    });
    return request;
  }

  @override
  void dispose() {
    cancelSearch();
    _disposed = true;
    _streamResolver.dispose();
    _fileDownloader.dispose();
    for (final client in _clients.toList()) {
      _close(client);
    }
    _searchClient = null;
    _resolving.clear();
  }
}
