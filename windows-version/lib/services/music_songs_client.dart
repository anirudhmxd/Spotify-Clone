import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../models/music.dart';

typedef MusicRequest =
    Future<Map<String, dynamic>> Function(
      String endpoint,
      Map<String, dynamic> body,
    );

class SongPage {
  final List<Track> tracks;
  final String? continuation;
  const SongPage(this.tracks, {this.continuation});
}

/// Reads typed songs from YouTube Music, never general YouTube search results.
class MusicSongsClient {
  MusicSongsClient({MusicRequest? request}) : _requestOverride = request;
  final MusicRequest? _requestOverride;
  HttpClient? _http;
  bool _closed = false;
  final _verified = <String, bool>{};
  final _checking = <String, Future<bool>>{};
  static const songType = 'MUSIC_VIDEO_TYPE_ATV';
  // Songs filter used by the upstream ytmusicapi search implementation.
  static const songsFilter = 'EgWKAQIIAWoMEA4QChADEAQQCRAF';

  Future<Map<String, dynamic>> _request(
    String endpoint,
    Map<String, dynamic> body,
  ) async {
    if (_closed) throw StateError('Music search is closed.');
    if (_requestOverride != null) return _requestOverride(endpoint, body);
    return (() async {
      final client = _http ??= HttpClient()
        ..connectionTimeout = const Duration(seconds: 8);
      final request = await client.postUrl(
        Uri.https('music.youtube.com', '/youtubei/v1/$endpoint', {
          'prettyPrint': 'false',
        }),
      );
      request.headers.contentType = ContentType.json;
      request.headers.set('Origin', 'https://music.youtube.com');
      request.headers.set('User-Agent', 'Mozilla/5.0');
      request.write(
        jsonEncode({
          'context': {
            'client': {
              'clientName': 'WEB_REMIX',
              'clientVersion': '1.20261026.03.00',
              'hl': 'en',
              'gl': 'US',
            },
          },
          ...body,
        }),
      );
      final response = await request.close();
      if (response.statusCode != 200) {
        await response.drain<void>();
        throw HttpException('Music catalog returned ${response.statusCode}.');
      }
      final result = jsonDecode(await utf8.decoder.bind(response).join());
      if (result is! Map<String, dynamic> || result.containsKey('error')) {
        throw const FormatException('Music catalog response unavailable.');
      }
      return result;
    })().timeout(const Duration(seconds: 12));
  }

  Future<SongPage> search(String query, {String? continuation}) async {
    final data = await _request('search', {
      'query': query,
      'params': songsFilter,
      'continuation': ?continuation,
    });
    final tracks = <Track>[];
    String? next;
    for (final key in ['musicShelfRenderer', 'musicShelfContinuation']) {
      for (final shelf in _nodes(data, key)) {
        // A filtered response may still contain shelves of another category.
        final title = _text(shelf['title']);
        if (title.isNotEmpty && title.toLowerCase() != 'songs') continue;
        for (final item in _list(shelf['contents'])) {
          final row = _at(item, ['musicResponsiveListItemRenderer']);
          final track = _searchSong(row);
          if (track != null) tracks.add(track);
        }
        for (final token in _nodes(
          shelf['continuations'],
          'nextContinuationData',
        )) {
          next = token['continuation'] as String?;
        }
        for (final token in _nodes(shelf['contents'], 'continuationCommand')) {
          next ??= token['token'] as String?;
        }
      }
    }
    return SongPage(_remember(tracks), continuation: next);
  }

  Future<List<Track>> related(String id) async {
    final data = await _request('next', {
      'videoId': id,
      'playlistId': 'RDAMVM$id',
      'enablePersistentPlaylistPanel': true,
      'isAudioOnly': true,
      'tunerSettingValue': 'AUTOMIX_SETTING_NORMAL',
      'params': 'wAEB',
    });
    final tracks = <Track>[];
    for (final panel in _nodes(data, 'playlistPanelRenderer')) {
      for (final item in _list(panel['contents'])) {
        // Counterparts can be music videos; inspect only the primary row.
        final primary = _at(item, [
          'playlistPanelVideoWrapperRenderer',
          'primaryRenderer',
        ]);
        final row = _at(primary ?? item, ['playlistPanelVideoRenderer']);
        if (row is! Map ||
            row.containsKey('unplayableText') ||
            row['isPlayable'] == false) {
          continue;
        }
        final endpoint = _at(row, ['navigationEndpoint', 'watchEndpoint']);
        if (!_songEndpoint(endpoint)) continue;
        final track = _track(
          id: row['videoId'],
          title: _text(row['title']),
          runs: _list(_at(row, ['longBylineText', 'runs'])),
          duration: _text(row['lengthText']),
          thumbnail: row['thumbnail'],
        );
        if (track != null && track.id != id) tracks.add(track);
      }
    }
    return _remember(tracks).take(25).toList();
  }

  /// Older libraries did not record content type. Verify before their first play.
  Future<bool> isSong(String id) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id)) return false;
    final known = _verified[id];
    if (known != null) return known;
    final pending = _checking[id];
    if (pending != null) return pending;
    final request = (() async {
      final data = await _request('player', {'videoId': id});
      final details = data['videoDetails'];
      final result =
          details is Map &&
          details['videoId'] == id &&
          details['musicVideoType'] == songType &&
          details['isLiveContent'] != true;
      _verified[id] = result;
      return result;
    })();
    _checking[id] = request;
    try {
      return await request;
    } finally {
      _checking.remove(id);
    }
  }

  List<Track> _remember(List<Track> tracks) {
    final unique = <String, Track>{};
    for (final track in tracks) {
      unique.putIfAbsent(track.id, () => track);
      _verified[track.id] = true;
    }
    return unique.values.toList();
  }

  static bool _songEndpoint(dynamic endpoint) =>
      _at(endpoint, [
        'watchEndpointMusicSupportedConfigs',
        'watchEndpointMusicConfig',
        'musicVideoType',
      ]) ==
      songType;

  static Track? _searchSong(dynamic row) {
    if (row is! Map ||
        row['isPlayable'] == false ||
        row['musicItemRendererDisplayPolicy'] ==
            'MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT') {
      return null;
    }
    final columns = _list(row['flexColumns']);
    if (columns.length < 2) return null;
    final title = _at(columns[0], [
      'musicResponsiveListItemFlexColumnRenderer',
      'text',
    ]);
    final endpoint =
        _at(row, [
          'overlay',
          'musicItemThumbnailOverlayRenderer',
          'content',
          'musicPlayButtonRenderer',
          'playNavigationEndpoint',
          'watchEndpoint',
        ]) ??
        _at(title, ['runs', 0, 'navigationEndpoint', 'watchEndpoint']);
    if (!_songEndpoint(endpoint)) return null;
    final id = _at(endpoint, ['videoId']);
    final itemId = _at(row, ['playlistItemData', 'videoId']);
    if (itemId != null && itemId != id) return null;
    final runs = _list(
      _at(columns[1], [
        'musicResponsiveListItemFlexColumnRenderer',
        'text',
        'runs',
      ]),
    );
    final duration =
        runs
            .map((r) => _at(r, ['text']))
            .whereType<String>()
            .where((s) => RegExp(r'^\d+(?::\d{2}){1,2}$').hasMatch(s))
            .firstOrNull ??
        '';
    return _track(
      id: id,
      title: _text(title),
      runs: runs,
      duration: duration,
      thumbnail: row['thumbnail'],
    );
  }

  static Track? _track({
    required dynamic id,
    required String title,
    required List<dynamic> runs,
    required String duration,
    required dynamic thumbnail,
  }) {
    if (id is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id) ||
        title.isEmpty) {
      return null;
    }
    final artists = <String>[];
    var album = '';
    for (final run in runs) {
      final type = _at(run, [
        'navigationEndpoint',
        'browseEndpoint',
        'browseEndpointContextSupportedConfigs',
        'browseEndpointContextMusicConfig',
        'pageType',
      ]);
      final text = _at(run, ['text']);
      if (text is! String) continue;
      if (type == 'MUSIC_PAGE_TYPE_ARTIST') artists.add(text);
      if (type == 'MUSIC_PAGE_TYPE_ALBUM') album = text;
    }
    // Unlinked artist names occur on some releases; the first metadata segment
    // still names the artist. Never treat view counts or durations as artists.
    final fallback = runs
        .takeWhile((r) => _at(r, ['text']) != ' • ')
        .map((r) => _at(r, ['text']) ?? '')
        .join();
    final artist = artists.isNotEmpty ? artists.join(', ') : fallback;
    if (artist.isEmpty) return null;
    final parts = duration.split(':').map(int.tryParse).toList();
    if (parts.length < 2 || parts.any((p) => p == null)) return null;
    final seconds = parts.fold<int>(0, (sum, part) => sum * 60 + part!);
    if (seconds <= 0) return null;
    // Thumbnail lists are nested differently in search and radio rows.
    final thumbnails = _thumbnailList(thumbnail);
    final artwork = thumbnails.isEmpty
        ? ''
        : (_at(thumbnails.last, ['url']) as String? ?? '');
    return Track(
      id: id,
      title: title,
      artist: artist,
      album: album.isEmpty ? 'Single' : album,
      artwork: artwork,
      durationMs: seconds * 1000,
      stream: 'https://music.youtube.com/watch?v=$id',
      isMusic: true,
    );
  }

  static List<dynamic> _thumbnailList(dynamic value) {
    if (value is Map) {
      if (value['thumbnails'] is List) return value['thumbnails'] as List;
      for (final child in value.values) {
        final list = _thumbnailList(child);
        if (list.isNotEmpty) return list;
      }
    }
    return const [];
  }

  static dynamic _at(dynamic value, List<Object> path) {
    for (final key in path) {
      if (key is int && value is List && key < value.length) {
        value = value[key];
      } else if (key is String && value is Map) {
        value = value[key];
      } else {
        return null;
      }
    }
    return value;
  }

  static String _text(dynamic value) => value is Map
      ? (_list(value['runs']).map((r) => _at(r, ['text']) ?? '').join())
      : '';
  static List<dynamic> _list(dynamic value) => value is List ? value : const [];
  static Iterable<Map> _nodes(dynamic value, String key) sync* {
    if (value is Map) {
      if (value[key] is Map) yield value[key] as Map;
      for (final child in value.values) {
        yield* _nodes(child, key);
      }
    } else if (value is List) {
      for (final child in value) {
        yield* _nodes(child, key);
      }
    }
  }

  void close() {
    _closed = true;
    _http?.close(force: true);
  }
}
