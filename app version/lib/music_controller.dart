import 'dart:async';

import 'package:flutter/foundation.dart';

import 'models/music.dart';
import 'services/music_api.dart';
import 'services/audio_engine.dart';

enum MusicPage { search, songs, library, playlist }

class MusicController extends ChangeNotifier {
  final MusicApi api;
  final AudioEngine audio;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  List<Playlist> playlists = [];
  List<Track> searchTracks = [], songs = [], queue = [];
  Track? current;
  String? activePlaylistId, queuePlaylistId;
  MusicPage page = MusicPage.search;
  String query = '', searchStatus = '', songsStatus = '', libraryStatus = '';
  String? notice;
  bool searching = false, loadingMore = false, hasMore = false;
  bool loadingSongs = false,
      loadingLibrary = false,
      mutating = false,
      loop = false;
  double volume = .7, _previousVolume = .7;
  int _searchId = 0, _pageNumber = 0, _playId = 0, _songsId = 0;
  int queueIndex = -1;
  bool _scored = false, _disposed = false, _advancing = false;
  Timer? _debounce;

  MusicController(this.api, this.audio) {
    _subscriptions.add(
      audio.positions.listen((_) {
        if (current != null &&
            !_scored &&
            audio.playing &&
            audio.duration.inMilliseconds > 0 &&
            audio.position.inMilliseconds / audio.duration.inMilliseconds >=
                .85) {
          _scored = true;
          unawaited(api.score(current!).catchError((Object _) {}));
        }
        _emit();
      }),
    );
    _subscriptions.add(
      audio.changes.listen(
        (_) => _emit(),
        onError: (Object e) => message('Playback failed: $e'),
      ),
    );
    _subscriptions.add(
      audio.completions.listen((_) {
        if (!loop) unawaited(next(recommend: true));
      }),
    );
    unawaited(
      audio
          .setVolume(volume)
          .catchError((Object e) => message('Could not set volume.')),
    );
  }
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  void message(String text) {
    notice = text;
    _emit();
  }

  void clearNotice() {
    notice = null;
  }

  String _error(Object e) => e.toString().replaceFirst('Exception: ', '');
  Playlist? get activePlaylist {
    for (final playlist in playlists) {
      if (playlist.id == activePlaylistId) return playlist;
    }
    return null;
  }

  void navigate(MusicPage target) {
    page = target;
    if (target != MusicPage.playlist) activePlaylistId = null;
    _emit();
    if (target == MusicPage.songs) unawaited(loadSongs());
  }

  void openPlaylist(Playlist playlist) {
    activePlaylistId = playlist.id;
    page = MusicPage.playlist;
    _emit();
  }

  Future<void> loadLibrary() async {
    if (loadingLibrary) return;
    loadingLibrary = true;
    libraryStatus = '';
    _emit();
    try {
      playlists = await api.playlists();
    } catch (e) {
      libraryStatus = _error(e);
    } finally {
      loadingLibrary = false;
      _emit();
    }
  }

  void search(String value, {bool immediate = false}) {
    _debounce?.cancel();
    final id = ++_searchId;
    api.cancelSearch();
    query = value.trim();
    _pageNumber = 0;
    searchTracks = [];
    hasMore = false;
    loadingMore = false;
    searching = query.isNotEmpty;
    searchStatus = searching ? 'Searching…' : '';
    _emit();
    if (!searching) return;
    if (immediate) {
      unawaited(_runSearch(id, query, 0));
    } else {
      _debounce = Timer(
        const Duration(milliseconds: 300),
        () => _runSearch(id, query, 0),
      );
    }
  }

  Future<void> _runSearch(int id, String term, int pageNumber) async {
    try {
      final data = await api.search(term, pageNumber);
      if (_disposed || id != _searchId) return;
      final tracks = decodeTracks(
        data['tracks'],
      ).where((t) => t.stream.isNotEmpty).toList();
      searchTracks = pageNumber == 0 ? tracks : [...searchTracks, ...tracks];
      _pageNumber = pageNumber;
      hasMore = data['hasMore'] == true && tracks.isNotEmpty;
      searchStatus = searchTracks.isEmpty
          ? 'No playable results found. Try another search.'
          : '';
    } catch (e) {
      if (id == _searchId) searchStatus = _error(e);
    } finally {
      if (id == _searchId) {
        searching = false;
        loadingMore = false;
        _emit();
      }
    }
  }

  Future<void> loadMore() async {
    if (searching || loadingMore || !hasMore) return;
    loadingMore = true;
    _emit();
    await _runSearch(++_searchId, query, _pageNumber + 1);
  }

  Future<void> loadSongs() async {
    final id = ++_songsId;
    loadingSongs = true;
    songsStatus = '';
    _emit();
    try {
      final tracks = await api.songs();
      if (id != _songsId || _disposed) return;
      songs = tracks;
      songsStatus = songs.isEmpty
          ? 'Songs you listen to fully will appear here.'
          : '';
    } catch (e) {
      if (id == _songsId) songsStatus = _error(e);
    } finally {
      if (id == _songsId) {
        loadingSongs = false;
        _emit();
      }
    }
  }

  Future<void> _mutation(Future<void> Function() action) async {
    if (mutating) return;
    mutating = true;
    _emit();
    try {
      await action();
    } catch (e) {
      message(_error(e));
    } finally {
      mutating = false;
      _emit();
    }
  }

  Future<void> createPlaylist(String name, {Track? track}) =>
      _mutation(() async {
        final playlist = await api.createPlaylist(name.trim());
        playlists = [...playlists, playlist];
        _emit();
        if (track != null) _replace(await api.addTrack(playlist.id, track));
        message('Playlist “${playlist.name}” created.');
      });
  Future<void> addTrack(Playlist playlist, Track track) => _mutation(() async {
    final duplicate = playlist.tracks.any((t) => t.id == track.id);
    _replace(await api.addTrack(playlist.id, track));
    message(
      duplicate
          ? 'This playlist already contains that song.'
          : 'Added to “${playlist.name}”.',
    );
  });
  Future<void> removeTrack(Playlist playlist, Track track) =>
      _mutation(() async {
        _replace(await api.removeTrack(playlist.id, track.id));
        message('Removed from “${playlist.name}”.');
      });
  Future<void> deletePlaylist(Playlist playlist) => _mutation(() async {
    await api.deletePlaylist(playlist.id);
    playlists = playlists.where((p) => p.id != playlist.id).toList();
    if (queuePlaylistId == playlist.id) queuePlaylistId = null;
    navigate(MusicPage.library);
    message('Deleted “${playlist.name}”.');
  });
  void _replace(Playlist playlist) {
    playlists = playlists
        .map((p) => p.id == playlist.id ? playlist : p)
        .toList();
    if (queuePlaylistId == playlist.id) {
      queue = [...playlist.tracks];
      queueIndex = queue.indexWhere((t) => t.id == current?.id);
    }
    _emit();
  }

  Future<void> playTracks(
    List<Track> tracks,
    int index, {
    String? playlistId,
  }) async {
    if (index < 0 || index >= tracks.length) return;
    if (current?.id == tracks[index].id && queuePlaylistId == playlistId) {
      await togglePlay();
      return;
    }
    queue = [...tracks];
    queueIndex = index;
    queuePlaylistId = playlistId;
    await _start(tracks[index]);
  }

  Future<void> playPlaylist(Playlist playlist) async {
    if (playlist.tracks.isEmpty) return;
    if (queuePlaylistId == playlist.id && current != null) {
      await togglePlay();
    } else {
      await playTracks(playlist.tracks, 0, playlistId: playlist.id);
    }
  }

  Future<void> _start(Track track) async {
    final id = ++_playId;
    current = track;
    _scored = false;
    _emit();
    try {
      await audio.load(api.url(track.stream).toString());
      if (_disposed || id != _playId) return;
      unawaited(
        audio.play().catchError((Object e) {
          if (id == _playId) {
            message('This song could not be played. Try another track.');
          }
        }),
      );
    } catch (e) {
      if (id == _playId) {
        message('This song could not be played. Try another track.');
      }
    }
    _emit();
  }

  Future<void> togglePlay() async {
    if (current == null) return;
    try {
      if (audio.playing) {
        await audio.pause();
      } else {
        if (audio.duration > Duration.zero &&
            audio.position >= audio.duration) {
          await audio.seek(Duration.zero);
        }
        unawaited(
          audio.play().catchError(
            (Object e) => message('This song could not be played.'),
          ),
        );
      }
    } catch (e) {
      message('Playback is unavailable. Try another song.');
    }
    _emit();
  }

  Future<void> next({bool recommend = false}) async {
    if (queue.isEmpty || _advancing) return;
    _advancing = true;
    final id = _playId;
    try {
      final nextIndex = queueIndex + 1;
      if (recommend && nextIndex >= queue.length && queuePlaylistId == null) {
        try {
          final additions = await api.recommend(queue);
          if (id != _playId || _disposed) return;
          queue.addAll(additions.where((t) => !queue.any((q) => q.id == t.id)));
        } catch (_) {
          /* Wrap the queue if recommendations are unavailable. */
        }
      }
      if (id != _playId || _disposed || queue.isEmpty) return;
      queueIndex = nextIndex % queue.length;
      await _start(queue[queueIndex]);
    } finally {
      _advancing = false;
    }
  }

  Future<void> previous() async {
    if (queue.isEmpty) return;
    if (audio.position > const Duration(seconds: 3)) {
      await seek(Duration.zero);
      return;
    }
    queueIndex = (queueIndex - 1) % queue.length;
    await _start(queue[queueIndex]);
  }

  Future<void> seek(Duration position) async {
    try {
      await audio.seek(position);
    } catch (_) {
      message('Could not seek in this song.');
    }
  }

  Future<void> setVolume(double value) async {
    volume = value;
    if (value > 0) _previousVolume = value;
    _emit();
    try {
      await audio.setVolume(value);
    } catch (_) {
      message('Could not change volume.');
    }
  }

  Future<void> mute() => setVolume(volume == 0 ? _previousVolume : 0);
  Future<void> toggleLoop() async {
    loop = !loop;
    _emit();
    try {
      await audio.setLoop(loop);
    } catch (_) {
      loop = !loop;
      message('Could not change repeat mode.');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_searchId;
    ++_playId;
    ++_songsId;
    _debounce?.cancel();
    api.dispose();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(audio.dispose());
    super.dispose();
  }
}
