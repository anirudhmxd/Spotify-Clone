import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/music.dart';
import '../models/experience.dart';

/// A serialized, atomically replaced local library. No network or server.
class LibraryStore {
  final Future<Directory> Function() directory;
  Future<void> _tail = Future<void>.value();
  Map<String, dynamic>? _snapshot;
  Directory? _resolvedDirectory;
  LibraryStore({Future<Directory> Function()? directory})
    : directory = directory ?? getApplicationSupportDirectory;

  Future<T> _transaction<T>(
    Future<T> Function(Map<String, dynamic>) action, {
    bool write = true,
  }) {
    final result = _tail.then((_) async {
      final dir = _resolvedDirectory ??= await directory();
      if (_snapshot == null) await dir.create(recursive: true);
      final file = File('${dir.path}/music_library.json');
      final backup = File('${file.path}.bak');
      Map<String, dynamic> data = {
        'playlists': <dynamic>[],
        'plays': <String, dynamic>{},
      };
      var recovered = false;
      if (_snapshot != null) {
        data = _snapshot!;
      } else if (await file.exists() || await backup.exists()) {
        try {
          data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        } catch (_) {
          // Restore the last successful version if the current file is damaged.
          if (!await backup.exists()) {
            throw const FormatException(
              'Your saved library could not be read. Its file has been preserved.',
            );
          }
          data =
              jsonDecode(await backup.readAsString()) as Map<String, dynamic>;
          recovered = true;
        }
      }
      // Mutations work on a copy: failed validation must not corrupt the cache.
      if (write) data = _copy(data) as Map<String, dynamic>;
      final value = await action(data);
      if (!write && !recovered) {
        _snapshot = data;
        return value;
      }
      final encoded = jsonEncode(data);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(encoded, flush: true);
      await temporary.rename(file.path);
      _snapshot = data;
      final backupTemporary = File('${backup.path}.tmp');
      await backupTemporary.writeAsString(encoded, flush: true);
      await backupTemporary.rename(backup.path);
      return value;
    });
    _tail = result.then<void>((_) {}, onError: (Object e, StackTrace s) {});
    return result;
  }

  static dynamic _copy(dynamic value) {
    if (value is Map) {
      return <String, dynamic>{
        for (final e in value.entries) e.key as String: _copy(e.value),
      };
    }
    if (value is List) return value.map(_copy).toList();
    return value;
  }

  List<Playlist> _playlists(Map<String, dynamic> data) =>
      (data['playlists'] as List? ?? [])
          .map((p) => Playlist.fromJson(Map<String, dynamic>.from(p as Map)))
          .toList();
  void _writePlaylists(Map<String, dynamic> data, List<Playlist> playlists) {
    data['playlists'] = playlists.map((p) => p.toJson()).toList();
  }

  Future<List<Playlist>> playlists() =>
      _transaction((data) async => _playlists(data), write: false);

  /// Preserve verified legacy songs in playlists, history and offline downloads.
  Future<void> confirmMusic(String id) => _transaction((data) async {
    void visit(dynamic value) {
      if (value is Map) {
        if (value['trackId'] == id && value.containsKey('trackName')) {
          value['isMusic'] = true;
        }
        for (final child in value.values) {
          visit(child);
        }
      } else if (value is List) {
        for (final child in value) {
          visit(child);
        }
      }
    }

    visit(data);
  });
  Future<Playlist> createPlaylist(String name) => _transaction((data) async {
    final clean = name.trim();
    if (clean.isEmpty) throw ArgumentError('Playlist name is required.');
    final playlist = Playlist(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: clean.length > 80 ? clean.substring(0, 80) : clean,
      tracks: [],
    );
    _writePlaylists(data, [..._playlists(data), playlist]);
    return playlist;
  });
  Future<void> deletePlaylist(String id) => _transaction((data) async {
    _writePlaylists(data, _playlists(data).where((p) => p.id != id).toList());
  });
  Future<Playlist> blendPlaylists(
    String name,
    List<String> playlistIds,
  ) => _transaction((data) async {
    final clean = name.trim();
    final ids = playlistIds.toSet().toList();
    if (clean.isEmpty || ids.length < 2) {
      throw ArgumentError('Enter a name and choose at least two playlists.');
    }
    final playlists = _playlists(data);
    final available = {for (final playlist in playlists) playlist.id: playlist};
    if (ids.any((id) => !available.containsKey(id))) {
      throw StateError('A selected playlist no longer exists.');
    }
    final songs = <String, Track>{};
    for (final id in ids) {
      for (final track in available[id]!.tracks) {
        if (!track.isSong) continue;
        songs.putIfAbsent(track.id, () => track);
        if (songs.length > 5000) {
          throw ArgumentError('A blend can contain at most 5,000 songs.');
        }
      }
    }
    final playlist = Playlist(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: clean.length > 80 ? clean.substring(0, 80) : clean,
      tracks: songs.values.toList(),
    );
    _writePlaylists(data, [...playlists, playlist]);
    return playlist;
  });
  Future<Playlist> _edit(String id, List<Track> Function(List<Track>) edit) =>
      _transaction((data) async {
        final playlists = _playlists(data);
        final index = playlists.indexWhere((p) => p.id == id);
        if (index < 0) throw StateError('Playlist no longer exists.');
        final old = playlists[index];
        final updated = Playlist(
          id: old.id,
          name: old.name,
          tracks: edit(old.tracks),
          description: old.description,
          pinned: old.pinned,
        );
        playlists[index] = updated;
        _writePlaylists(data, playlists);
        return updated;
      });
  Future<Playlist> addTrack(String id, Track track) => _edit(
    id,
    (tracks) =>
        tracks.any((t) => t.id == track.id) ? tracks : [...tracks, track],
  );
  Future<Playlist> removeTrack(String id, String trackId) =>
      _edit(id, (tracks) => tracks.where((t) => t.id != trackId).toList());
  Future<void> score(Track track) => _transaction((data) async {
    final plays = Map<String, dynamic>.from(data['plays'] as Map? ?? {});
    final old = plays[track.id] as Map?;
    plays[track.id] = {
      ...track.toJson(),
      'fullPlays': ((old?['fullPlays'] as num?)?.toInt() ?? 0) + 1,
    };
    data['plays'] = plays;
  });
  Future<List<Track>> songs() => _transaction((data) async {
    final songs = (data['plays'] as Map? ?? {}).values
        .map((value) => Track.fromJson(Map<String, dynamic>.from(value as Map)))
        .toList();
    songs.sort((a, b) => b.fullPlays.compareTo(a.fullPlays));
    return songs;
  }, write: false);

  Future<LibraryProfile> profile() => _transaction(
    (data) async => LibraryProfile(
      settings: AppSettings.fromJson(
        Map<String, dynamic>.from(data['settings'] as Map? ?? {}),
      ),
      liked: decodeTracks(data['liked']),
      recent: decodeTracks(data['recent']),
      searches: (data['searches'] as List? ?? []).cast<String>().toList(),
      listening: (data['listening'] as Map? ?? {}).values
          .map((v) => ListenDay.fromJson(Map<String, dynamic>.from(v as Map)))
          .toList(),
      downloads: (data['downloads'] as Map? ?? {}).values
          .map(
            (v) => DownloadRecord.fromJson(Map<String, dynamic>.from(v as Map)),
          )
          .toList(),
    ),
    write: false,
  );

  Future<Map<String, dynamic>?> playbackState() =>
      _transaction((data) async {
        final value = data['playbackState'];
        return value is Map ? Map<String, dynamic>.from(value) : null;
      }, write: false);

  Future<void> savePlaybackState(Map<String, dynamic> state) =>
      _transaction((data) async {
        data['playbackState'] = state;
      });

  Future<void> saveSettings(AppSettings settings) => _transaction((data) async {
    data['settings'] = settings.toJson();
  });
  Future<void> setLiked(Track track, bool liked) => _transaction((data) async {
    final tracks = decodeTracks(
      data['liked'],
    ).where((t) => t.id != track.id).toList();
    if (liked) tracks.insert(0, track);
    data['liked'] = tracks.map((t) => t.toJson()).toList();
  });
  Future<void> rememberSearch(String term) => _transaction((data) async {
    final searches = (data['searches'] as List? ?? [])
        .whereType<String>()
        .where((s) => s != term)
        .toList();
    if (term.trim().isNotEmpty) searches.insert(0, term.trim());
    data['searches'] = searches.take(12).toList();
  });
  Future<void> recordListening(
    Track track,
    int milliseconds,
    DateTime at,
    bool newPlay,
  ) => _transaction((data) async {
    if (milliseconds <= 0) return;
    final day = DateTime(at.year, at.month, at.day);
    final key = '${day.toIso8601String()}|${track.id}';
    final all = Map<String, dynamic>.from(data['listening'] as Map? ?? {});
    final old = all[key] as Map?;
    all[key] = ListenDay(
      track: track,
      day: day,
      milliseconds:
          ((old?['milliseconds'] as num?)?.toInt() ?? 0) + milliseconds,
      plays: ((old?['plays'] as num?)?.toInt() ?? 0) + (newPlay ? 1 : 0),
    ).toJson();
    data['listening'] = all;
    data['recent'] = [
      track,
      ...decodeTracks(data['recent']).where((t) => t.id != track.id),
    ].take(100).map((t) => t.toJson()).toList();
  });
  Future<Playlist> editPlaylist(Playlist playlist) =>
      _transaction((data) async {
        if (playlist.name.trim().isEmpty) {
          throw ArgumentError('Playlist name is required.');
        }
        final lists = _playlists(data);
        final index = lists.indexWhere((p) => p.id == playlist.id);
        if (index < 0) throw StateError('Playlist no longer exists.');
        lists[index] = playlist;
        _writePlaylists(data, lists);
        return playlist;
      });
  Future<void> saveDownload(DownloadRecord record) => _transaction((
    data,
  ) async {
    final records = Map<String, dynamic>.from(data['downloads'] as Map? ?? {});
    records[record.track.id] = record.toJson();
    data['downloads'] = records;
  });
  Future<void> removeDownload(String id) => _transaction((data) async {
    final records = Map<String, dynamic>.from(data['downloads'] as Map? ?? {});
    records.remove(id);
    data['downloads'] = records;
  });
  Future<void> clearHistory() => _transaction((data) async {
    data['listening'] = <String, dynamic>{};
    data['plays'] = <String, dynamic>{};
    data['recent'] = [];
    data['searches'] = [];
  });
  Future<String> exportLibrary() => _transaction(
    (data) async => jsonEncode({
      'version': 1,
      'playlists': data['playlists'] ?? [],
      'liked': data['liked'] ?? [],
    }),
    write: false,
  );
  Future<void> importLibrary(String text) => _transaction((data) async {
    final decoded = jsonDecode(text);
    if (decoded is! Map ||
        decoded['version'] != 1 ||
        decoded['playlists'] is! List) {
      throw const FormatException('Not a supported library export.');
    }
    final incoming = (decoded['playlists'] as List)
        .map((p) => Playlist.fromJson(Map<String, dynamic>.from(p as Map)))
        .toList();
    final liked = decodeTracks(decoded['liked']);
    bool valid(Track track) =>
        RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(track.id);
    // Device file paths are never trusted or copied from an import.
    final lists = _playlists(data);
    for (var i = 0; i < incoming.length; i++) {
      final p = incoming[i];
      lists.add(
        Playlist(
          id: '${DateTime.now().microsecondsSinceEpoch}_$i',
          name: p.name,
          description: p.description,
          tracks: {
            for (final t in p.tracks.where(valid)) t.id: t,
          }.values.toList(),
        ),
      );
    }
    _writePlaylists(data, lists);
    final merged = {for (final t in decodeTracks(data['liked'])) t.id: t};
    for (final t in liked.where(valid)) {
      merged[t.id] = t;
    }
    data['liked'] = merged.values.map((t) => t.toJson()).toList();
  });
}
