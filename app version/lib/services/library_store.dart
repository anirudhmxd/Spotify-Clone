import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/music.dart';

/// A serialized, atomically replaced local library. No network or server.
class LibraryStore {
  final Future<Directory> Function() directory;
  Future<void> _tail = Future<void>.value();
  LibraryStore({Future<Directory> Function()? directory})
    : directory = directory ?? getApplicationSupportDirectory;

  Future<T> _transaction<T>(Future<T> Function(Map<String, dynamic>) action) {
    final result = _tail.then((_) async {
      final dir = await directory();
      await dir.create(recursive: true);
      final file = File('${dir.path}/music_library.json');
      final backup = File('${file.path}.bak');
      Map<String, dynamic> data = {
        'playlists': <dynamic>[],
        'plays': <String, dynamic>{},
      };
      if (await file.exists() || await backup.exists()) {
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
        }
      }
      final previous = jsonEncode(data);
      final value = await action(data);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(jsonEncode(data), flush: true);
      if (await file.exists()) {
        // Save the successfully parsed state, never a corrupt original.
        await backup.writeAsString(previous, flush: true);
      }
      await temporary.rename(file.path);
      return value;
    });
    _tail = result.then<void>((_) {}, onError: (Object e, StackTrace s) {});
    return result;
  }

  List<Playlist> _playlists(Map<String, dynamic> data) =>
      (data['playlists'] as List? ?? [])
          .map((p) => Playlist.fromJson(Map<String, dynamic>.from(p as Map)))
          .toList();
  void _writePlaylists(Map<String, dynamic> data, List<Playlist> playlists) {
    data['playlists'] = playlists.map((p) => p.toJson()).toList();
  }

  Future<List<Playlist>> playlists() =>
      _transaction((data) async => _playlists(data));
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
  });
}
