import 'dart:async';
import 'dart:io';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;
import '../models/music.dart';
import '../models/experience.dart';
import 'music_repository.dart';

abstract class MusicCatalog {
  Future<SearchPage> search(String query, int page);
  void cancelSearch();
  Future<String> resolveAudio(Track track);
  Future<String> download(Track track, Directory directory);
  void dispose();
}

class YoutubeCatalog implements MusicCatalog {
  final Set<yt.YoutubeExplode> _clients = {};
  yt.YoutubeExplode? _searchClient;
  String? _query;
  final List<yt.VideoSearchList> _pages = [];
  final List<Track> _playlist = [];
  StreamIterator<Track>? _playlistIterator;
  bool _playlistEnded = false;
  bool _disposed = false;
  AudioQuality streamingQuality = AudioQuality.high,
      downloadQuality = AudioQuality.high;
  yt.YoutubeExplode _client() {
    if (_disposed) throw StateError('Music catalog is closed.');
    final client = yt.YoutubeExplode();
    _clients.add(client);
    return client;
  }

  void _close(yt.YoutubeExplode client) {
    if (_clients.remove(client)) client.close();
  }

  @override
  void cancelSearch() {
    if (_searchClient != null) _close(_searchClient!);
    _searchClient = null;
    _query = null;
    _pages.clear();
    _playlist.clear();
    if (_playlistIterator != null) unawaited(_playlistIterator!.cancel());
    _playlistIterator = null;
    _playlistEnded = false;
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
      _searchClient = _client();
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

  Future<yt.AudioOnlyStreamInfo> _audio(
    yt.YoutubeExplode client,
    Track track,
    AudioQuality quality,
  ) async {
    final manifest = await client.videos.streams.getManifest(
      track.id,
      // These clients work in Dart without installing a separate JavaScript runtime.
      ytClients: [
        yt.YoutubeApiClient.androidSdkless,
        yt.YoutubeApiClient.androidVr,
      ],
      requireWatchPage: false,
    );
    final streams = manifest.audioOnly.where(
      (s) => s.container == yt.StreamContainer.mp4,
    );
    if (streams.isEmpty) {
      throw Exception('No compatible audio is available for this song.');
    }
    return selectAudio(streams.toList(), quality);
  }

  static yt.AudioOnlyStreamInfo selectAudio(
    List<yt.AudioOnlyStreamInfo> streams,
    AudioQuality quality,
  ) {
    final ordered = streams..sort((a, b) => a.bitrate.compareTo(b.bitrate));
    if (quality == AudioQuality.dataSaver) return ordered.first;
    if (quality == AudioQuality.balanced) return ordered[ordered.length ~/ 2];
    return ordered.last;
  }

  @override
  Future<String> resolveAudio(Track track) async {
    final client = _client();
    try {
      final info = await _audio(
        client,
        track,
        streamingQuality,
      ).timeout(const Duration(seconds: 25));
      return info.url.toString();
    } on TimeoutException {
      throw Exception('Audio loading took too long. Try again.');
    } finally {
      _close(client);
    }
  }

  @override
  Future<String> download(Track track, Directory directory) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(track.id)) {
      throw ArgumentError('Invalid song ID.');
    }
    await directory.create(recursive: true);
    final destination = File('${directory.path}/${track.id}.m4a');
    if (await destination.exists() && await destination.length() > 0) {
      return destination.path;
    }
    final client = _client();
    final temporary = File('${destination.path}.part');
    IOSink? sink;
    Timer? deadline;
    try {
      final info = await _audio(
        client,
        track,
        downloadQuality,
      ).timeout(const Duration(seconds: 25));
      deadline = Timer(const Duration(minutes: 10), () => _close(client));
      sink = temporary.openWrite();
      await sink.addStream(
        client.videos.streams.get(info).timeout(const Duration(seconds: 30)),
      );
      await sink.flush();
      await sink.close();
      sink = null;
      if (await temporary.length() != info.size.totalBytes) {
        throw Exception('The download was incomplete. Please retry.');
      }
      await temporary.rename(destination.path);
      return destination.path;
    } finally {
      deadline?.cancel();
      _close(client);
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {}
      }
      if (await temporary.exists()) await temporary.delete();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final client in _clients.toList()) {
      _close(client);
    }
    _searchClient = null;
  }
}
