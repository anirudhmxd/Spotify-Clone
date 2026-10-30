import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'models/music.dart';
import 'models/experience.dart';
import 'services/music_repository.dart';
import 'services/audio_engine.dart';
import 'services/audio_diagnostics.dart';

enum MusicPage {
  home,
  search,
  songs,
  library,
  playlist,
  liked,
  downloads,
  history,
  wrapped,
  settings,
  artist,
}

class MusicController extends ChangeNotifier {
  final MusicRepository repository;
  final AudioEngine audio;
  final ValueNotifier<Duration> playbackPosition = ValueNotifier(Duration.zero);
  final Map<String, ({SearchPage page, DateTime expires})> _searchCache = {};
  bool loadingRecommendations = false;

  final List<StreamSubscription<dynamic>> _subscriptions = [];
  List<Playlist> playlists = [];
  List<Track> searchTracks = [], songs = [], queue = [];
  Track? current;
  String? activePlaylistId, queuePlaylistId;
  MusicPage page = MusicPage.home;
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
  final Set<String> downloading = {};
  bool downloadingBatch = false;
  bool resolvingAudio = false;
  String? _loadedTrackId;
  LibraryProfile profile = const LibraryProfile();
  AppSettings settings = const AppSettings();
  RepeatMode repeatMode = RepeatMode.off;
  bool shuffle = false;
  final Random random;
  final DateTime Function() now;
  final List<Track> _originalQueue = [];
  String artist = '';
  String libraryFilter = '', librarySort = 'recent';
  DateTime? sleepUntil;
  bool sleepAfterTrack = false;
  Timer? _sleepTimer, _settingsTimer;
  int _lastPosition = 0, _pendingListening = 0;
  bool _newListen = true;
  Stopwatch? _playStartupClock;
  bool _reportedPlaybackProgress = false;
  int _sourceId = 0;
  int? _completedSourceId;
  Future<void> _listeningWrite = Future<void>.value();
  bool _scored = false, _disposed = false, _advancing = false;
  Timer? _debounce, _prefetchTimer;

  MusicController(
    this.repository,
    this.audio, {
    Random? random,
    DateTime Function()? now,
  }) : random = random ?? Random(),
       now = now ?? DateTime.now {
    _subscriptions.add(
      audio.positions.listen((_) {
        _sampleListening();
        playbackPosition.value = boundedPosition;
        if (!_reportedPlaybackProgress &&
            !resolvingAudio &&
            audio.playing &&
            !audio.loading &&
            _loadedTrackId == current?.id &&
            audio.position.inMilliseconds >= 100) {
          _reportedPlaybackProgress = true;
          AudioDiagnostics.log(
            'play.progress_started',
            'track=${current?.id} ms=${_playStartupClock?.elapsedMilliseconds} position_ms=${audio.position.inMilliseconds}',
          );
        }
        final end = expectedDuration;
        if (!resolvingAudio &&
            audio.playing &&
            !audio.loading &&
            end > Duration.zero &&
            audio.position >= end + const Duration(seconds: 1)) {
          unawaited(_finishPlayback());
        }
      }),
    );
    _subscriptions.add(
      audio.changes.listen((_) {
        if (!audio.playing) unawaited(flushListening());
        _emit();
      }, onError: (Object e) => message('Playback failed: $e')),
    );
    _subscriptions.add(
      audio.completions.listen((_) => unawaited(_finishPlayback())),
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

  String _error(Object e) {
    if (e is FormatException) {
      return 'Some music information could not be read. Please try again.';
    }
    return e.toString().replaceFirst('Exception: ', '');
  }

  void _prepareNext() {
    final nextIndex = queueIndex + 1;
    _prepareCandidates(
      nextIndex >= 0 && nextIndex < queue.length
          ? [queue[nextIndex]]
          : const [],
    );
  }

  void _prepareCandidates(Iterable<Track> tracks) {
    _prefetchTimer?.cancel();
    if (_disposed ||
        settings.offline ||
        downloading.isNotEmpty ||
        downloadingBatch) {
      return;
    }
    final ids = <String>{};
    final candidates = tracks
        .where((t) => t.id != current?.id && ids.add(t.id))
        .take(2)
        .toList();
    if (candidates.isEmpty) return;
    _prefetchTimer = Timer(const Duration(milliseconds: 350), () {
      if (_disposed ||
          settings.offline ||
          resolvingAudio ||
          downloading.isNotEmpty ||
          downloadingBatch) {
        return;
      }
      for (final track in candidates) {
        unawaited(repository.prepareAudio(track).catchError((Object _) {}));
      }
    });
  }

  /// Prefer catalog duration when the platform reports an incorrect MP4 timeline.
  Duration get expectedDuration {
    final ms = current?.durationMs ?? 0;
    if (ms > 0) return Duration(milliseconds: ms);
    return audio.duration;
  }

  Duration get boundedPosition {
    if (resolvingAudio) return Duration.zero;
    final end = expectedDuration;
    final ms = audio.position.inMilliseconds;
    return Duration(
      milliseconds: end > Duration.zero
          ? ms.clamp(0, end.inMilliseconds)
          : max(0, ms),
    );
  }

  Future<void> _finishPlayback() async {
    if (_disposed ||
        resolvingAudio ||
        _loadedTrackId != current?.id ||
        _completedSourceId == _sourceId) {
      return;
    }
    final id = _playId;
    _completedSourceId = _sourceId;
    AudioDiagnostics.log(
      'play.end',
      'track=${current?.id} position_ms=${audio.position.inMilliseconds} expected_ms=${expectedDuration.inMilliseconds}',
    );
    // Stop immediately, including while waiting for recommendations.
    await audio.pause();
    if (_disposed || id != _playId) return;
    await flushListening();
    if (_disposed || id != _playId) return;
    if (sleepAfterTrack) {
      sleepAfterTrack = false;
      await pause();
    } else if (loop) {
      await seek(Duration.zero);
      if (_disposed || id != _playId) return;
      unawaited(audio.play());
    } else {
      await next(recommend: true);
    }
  }

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
    if ([
      MusicPage.home,
      MusicPage.liked,
      MusicPage.downloads,
      MusicPage.history,
      MusicPage.wrapped,
      MusicPage.settings,
    ].contains(target)) {
      unawaited(flushListening().then((_) => refreshProfile()));
    }
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
      playlists = await repository.playlists();
      await refreshProfile(applySettings: true);
    } catch (e) {
      libraryStatus = _error(e);
    } finally {
      loadingLibrary = false;
      _emit();
    }
  }

  void search(String value, {bool immediate = false}) {
    final term = value.trim();
    if (term == query && searching && !(_debounce?.isActive ?? false)) return;
    _debounce?.cancel();
    _prefetchTimer?.cancel();
    final id = ++_searchId;
    repository.cancelSearch();
    query = term;
    _pageNumber = 0;
    if (query.isEmpty) searchTracks = [];
    hasMore = false;
    loadingMore = false;
    searching = query.isNotEmpty;
    searchStatus = '';
    _emit();
    if (!searching) return;
    if (immediate || _cachedSearch(query, 0) != null) {
      unawaited(_runSearch(id, query, 0));
    } else {
      _debounce = Timer(
        const Duration(milliseconds: 180),
        () => _runSearch(id, query, 0),
      );
    }
  }

  SearchPage? _cachedSearch(String term, int page) {
    if (settings.offline) return null;
    final cached = _searchCache['${term.toLowerCase()}/$page'];
    return cached != null && now().isBefore(cached.expires)
        ? cached.page
        : null;
  }

  Future<void> _runSearch(int id, String term, int pageNumber) async {
    try {
      final data =
          _cachedSearch(term, pageNumber) ??
          await repository
              .search(term, pageNumber)
              .timeout(const Duration(seconds: 20));
      if (!settings.offline && data.tracks.isNotEmpty) {
        final key = '${term.toLowerCase()}/$pageNumber';
        _searchCache.remove(key);
        if (_searchCache.length >= 30) {
          _searchCache.remove(_searchCache.keys.first);
        }
        _searchCache[key] = (
          page: data,
          expires: now().add(const Duration(minutes: 5)),
        );
      }
      if (_disposed || id != _searchId) return;
      final tracks = data.tracks;
      searchTracks = pageNumber == 0
          ? tracks
          : [
              ...searchTracks,
              ...tracks.where(
                (t) => !searchTracks.any((old) => old.id == t.id),
              ),
            ];
      if (pageNumber == 0 && !settings.privateSession) {
        unawaited(repository.rememberSearch(term).catchError((Object _) {}));
      }
      if (pageNumber == 0 && searchTracks.isNotEmpty) {
        _prepareCandidates(searchTracks.take(2));
      }
      _pageNumber = pageNumber;
      hasMore = data.hasMore && tracks.isNotEmpty;
      searchStatus = searchTracks.isEmpty
          ? 'No playable results found. Try another search.'
          : '';
    } catch (e) {
      if (id == _searchId) {
        if (pageNumber == 0) searchTracks = [];
        if (e is TimeoutException) repository.cancelSearch();
        searchStatus = e is TimeoutException
            ? 'Search took too long. Please try again.'
            : _error(e);
      }
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
      final tracks = await repository.recommend(
        current == null ? [] : [current!],
      );
      if (id != _songsId || _disposed) return;
      songs = tracks;
      songsStatus = songs.isEmpty
          ? 'Play or like a song to discover related music. Pull in fresh suggestions with Refresh.'
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
        final playlist = await repository.createPlaylist(name.trim());
        playlists = [...playlists, playlist];
        _emit();
        if (track != null) {
          _replace(await repository.addTrack(playlist.id, track));
        }
        message('Playlist “${playlist.name}” created.');
      });
  Future<void> addTrack(Playlist playlist, Track track) => _mutation(() async {
    final duplicate = playlist.tracks.any((t) => t.id == track.id);
    _replace(await repository.addTrack(playlist.id, track));
    message(
      duplicate
          ? 'This playlist already contains that song.'
          : 'Added to “${playlist.name}”.',
    );
  });
  Future<void> removeTrack(Playlist playlist, Track track) =>
      _mutation(() async {
        _replace(await repository.removeTrack(playlist.id, track.id));
        message('Removed from “${playlist.name}”.');
      });
  Future<void> deletePlaylist(Playlist playlist) => _mutation(() async {
    await repository.deletePlaylist(playlist.id);
    playlists = playlists.where((p) => p.id != playlist.id).toList();
    if (queuePlaylistId == playlist.id) queuePlaylistId = null;
    navigate(MusicPage.library);
    message('Deleted “${playlist.name}”.');
  });
  void _replace(Playlist playlist) {
    playlists = playlists
        .map((p) => p.id == playlist.id ? playlist : p)
        .toList();
    _emit();
  }

  Future<void> playTracks(
    List<Track> tracks,
    int index, {
    String? playlistId,
  }) async {
    if (index < 0 || index >= tracks.length) return;
    if (current?.id == tracks[index].id &&
        queuePlaylistId == playlistId &&
        listEquals(
          tracks.map((t) => t.id).toList(),
          _originalQueue.map((t) => t.id).toList(),
        )) {
      await togglePlay();
      return;
    }
    _originalQueue
      ..clear()
      ..addAll(tracks);
    queue = [...tracks];
    queueIndex = index;
    if (shuffle) {
      final selected = queue.removeAt(index);
      queue.shuffle(random);
      queue.insert(0, selected);
      queueIndex = 0;
    }
    queuePlaylistId = playlistId;
    await _start(queue[queueIndex]);
  }

  /// A search selection starts a station; explicit playlists keep their order.
  Future<void> playRadio(Track seed) async {
    if (current?.id == seed.id && queuePlaylistId == null) {
      await togglePlay();
      return;
    }
    final playback = playTracks([seed], 0);
    final id = _playId;
    if (settings.autoplay) unawaited(_fillRadio(seed, id));
    await playback;
  }

  Future<void> _fillRadio(Track seed, int id) async {
    loadingRecommendations = true;
    _emit();
    try {
      final additions = await repository.recommend([seed]);
      if (_disposed || id != _playId || !settings.autoplay) return;
      final ids = queue.map((t) => t.id).toSet();
      final unique = additions.where((t) => ids.add(t.id)).toList();
      queue.addAll(unique);
      _originalQueue.addAll(unique);
      if (!resolvingAudio) _prepareNext();
    } catch (_) {
      // A recommendation outage must never interrupt the selected song.
    } finally {
      if (id == _playId) {
        loadingRecommendations = false;
        _emit();
      }
    }
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
    _sourceId++;
    _completedSourceId = null;
    final playTimer = Stopwatch()..start();
    _playStartupClock = playTimer;
    _reportedPlaybackProgress = false;
    AudioDiagnostics.log('play.start', 'track=${track.id} selection=$id');
    _prefetchTimer?.cancel();
    unawaited(flushListening());
    if (_disposed || id != _playId) return;
    loadingRecommendations = false;
    current = track;
    playbackPosition.value = Duration.zero;
    _loadedTrackId = null;
    _lastPosition = 0;
    _newListen = true;
    resolvingAudio = true;
    _scored = false;
    _emit();
    try {
      await audio.pause();
      if (_disposed || id != _playId) return;
      final lookupTimer = Stopwatch()..start();
      final source = await repository.resolveAudio(track);
      AudioDiagnostics.log(
        'play.lookup_ready',
        'track=${track.id} ms=${lookupTimer.elapsedMilliseconds}',
      );
      if (_disposed || id != _playId) return;
      try {
        await _loadSource(source);
      } catch (error) {
        AudioDiagnostics.log(
          'play.source_failed',
          'track=${track.id} ms=${playTimer.elapsedMilliseconds} error=$error',
        );
        if (_disposed || id != _playId) return;
        // A rejected direct URL is recovered through the repository's audio source fallback.
        if (!source.startsWith('http')) rethrow;
        final fresh = await repository.resolveAudio(track, refreshStream: true);
        if (_disposed || id != _playId) return;
        try {
          await _loadSource(fresh);
        } catch (error) {
          AudioDiagnostics.log(
            'play.refreshed_source_failed',
            'track=${track.id} ms=${playTimer.elapsedMilliseconds} error=$error',
          );
          if (_disposed || id != _playId) return;
          if (!fresh.startsWith('http')) rethrow;
          final local = await repository.resolveAudio(
            track,
            preferDownload: true,
          );
          if (_disposed || id != _playId) return;
          await _loadSource(local);
        }
      }
      if (_disposed || id != _playId) return;
      await audio.setSpeed(settings.speed);
      if (audio.supportsEqualizer) await audio.setEqualizer(settings.equalizer);
      if (_disposed || id != _playId) return;
      _loadedTrackId = track.id;
      AudioDiagnostics.log(
        'play.loaded',
        'track=${track.id} ms=${playTimer.elapsedMilliseconds}',
      );
      unawaited(
        audio.play().catchError((Object e) {
          if (id == _playId) {
            message('This song could not be played. Try another track.');
          }
        }),
      );
    } catch (e) {
      if (id == _playId) {
        message('This song could not be played. ${_error(e)}');
      }
    }
    if (id == _playId) {
      resolvingAudio = false;
      _emit();
      if (_loadedTrackId == track.id) _prepareNext();
    }
  }

  Future<void> _loadSource(String source) async {
    final clock = Stopwatch()..start();
    // Catalog durations are rounded; allow the final fraction of a second.
    final ms = current?.durationMs ?? 0;
    final end = ms > 0 ? Duration(milliseconds: ms + 1000) : null;
    final uri = Uri.parse(source);
    final remote = uri.scheme == 'https' || uri.scheme == 'http';
    AudioDiagnostics.log(
      'play.source_load_start',
      'kind=${remote ? 'stream' : 'file'} clip_end_ms=${end?.inMilliseconds}',
    );
    try {
      if (remote) {
        await audio.load(source, end: end).timeout(const Duration(seconds: 6));
      } else {
        await audio
            .loadFile(uri.toFilePath(), end: end)
            .timeout(const Duration(seconds: 30));
      }
      AudioDiagnostics.log(
        'play.source_load_ready',
        'kind=${remote ? 'stream' : 'file'} ms=${clock.elapsedMilliseconds}',
      );
    } catch (error) {
      AudioDiagnostics.log(
        'play.source_load_failed',
        'ms=${clock.elapsedMilliseconds} error=$error',
      );
      rethrow;
    }
  }

  Future<void> togglePlay() async {
    if (current == null) return;
    if (resolvingAudio) {
      await pause();
      return;
    }
    if (_loadedTrackId != current!.id) {
      await _start(current!);
      return;
    }
    try {
      if (audio.playing) {
        await pause();
      } else {
        // Use expectedDuration (from YouTube metadata) instead of
        // audio.duration, because AVFoundation on macOS misreports
        // the duration of fragmented MP4 downloads (often doubling it).
        final duration = expectedDuration;
        if (duration > Duration.zero && audio.position >= duration) {
          await flushListening();
          _newListen = true;
          _scored = false;
          await seek(Duration.zero);
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

  Future<void> next({bool recommend = true}) async {
    if (queue.isEmpty || _advancing) return;
    _advancing = true;
    final id = _playId;
    try {
      final nextIndex = queueIndex + 1;
      if (recommend &&
          repeatMode != RepeatMode.all &&
          settings.autoplay &&
          nextIndex >= queue.length) {
        try {
          final additions = await repository.recommend(queue);
          if (id != _playId || _disposed) return;
          final ids = queue.map((t) => t.id).toSet();
          final unique = additions.where((t) => ids.add(t.id)).toList();
          queue.addAll(unique);
          _originalQueue.addAll(unique);
        } catch (_) {
          // Existing queued songs remain playable if recommendations fail.
        }
      }
      if (id != _playId || _disposed || queue.isEmpty) return;
      if (recommend &&
          nextIndex >= queue.length &&
          repeatMode != RepeatMode.all) {
        await pause();
        return;
      }
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
      final end = expectedDuration;
      final target = Duration(
        milliseconds: end > Duration.zero
            ? position.inMilliseconds.clamp(0, end.inMilliseconds)
            : max(0, position.inMilliseconds),
      );
      if (end <= Duration.zero || target < end) _completedSourceId = null;
      _lastPosition = target.inMilliseconds;
      await audio.seek(target);
      playbackPosition.value = boundedPosition;
      _emit();
    } catch (_) {
      message('Could not seek in this song.');
    }
  }

  Future<void> setVolume(double value) async {
    volume = value.clamp(0, 1);
    settings = settings.copyWith(volume: volume);
    _settingsTimer?.cancel();
    _settingsTimer = Timer(
      const Duration(milliseconds: 400),
      () => _persistSettings(),
    );
    if (value > 0) _previousVolume = value;
    _emit();
    try {
      await audio.setVolume(value);
    } catch (_) {
      message('Could not change volume.');
    }
  }

  Future<void> mute() => setVolume(volume == 0 ? _previousVolume : 0);
  Future<void> toggleLoop() => setRepeat(
    RepeatMode.values[(repeatMode.index + 1) % RepeatMode.values.length],
  );
  Future<void> setRepeat(RepeatMode value) async {
    final previous = repeatMode;
    repeatMode = value;
    loop = value == RepeatMode.one && !sleepAfterTrack;
    _emit();
    try {
      await audio.setLoop(loop);
    } catch (_) {
      repeatMode = previous;
      loop = previous == RepeatMode.one && !sleepAfterTrack;
      message('Could not change repeat mode.');
    }
  }

  Future<String?> download(Track track, {bool refresh = true}) async {
    if (_disposed || downloading.contains(track.id)) return null;
    _prefetchTimer?.cancel();
    downloading.add(track.id);
    _emit();
    try {
      final path = await repository.download(track);
      if (refresh && !_disposed) await refreshProfile();
      return path;
    } catch (e) {
      message('Download failed. ${_error(e)}');
      return null;
    } finally {
      downloading.remove(track.id);
      _emit();
    }
  }

  Future<void> downloadTracks(List<Track> tracks) async {
    if (downloadingBatch || _disposed) return;
    final pending = {
      for (final track in tracks)
        if (!isDownloaded(track) && !track.id.startsWith('local_'))
          track.id: track,
    }.values.toList();
    if (pending.isEmpty) return;
    downloadingBatch = true;
    _prefetchTimer?.cancel();
    _emit();
    var index = 0;
    Future<void> worker() async {
      while (!_disposed && index < pending.length) {
        final track = pending[index++];
        if (!isDownloaded(track)) await download(track, refresh: false);
      }
    }

    try {
      await Future.wait([worker(), worker()]);
      if (!_disposed) await refreshProfile();
    } finally {
      downloadingBatch = false;
      _emit();
    }
  }

  void _sampleListening() {
    final position = audio.position.inMilliseconds;
    final delta = position - _lastPosition;
    _lastPosition = position;
    if (delta < 0 && loop && position < 1500) {
      unawaited(flushListening());
      _scored = false;
      _newListen = true;
    }
    if (current == null ||
        resolvingAudio ||
        !audio.playing ||
        audio.loading ||
        delta <= 0 ||
        delta > 5000 ||
        settings.privateSession) {
      return;
    }
    _pendingListening += (delta / settings.speed).round();
    // Use expectedDuration (authoritative YouTube metadata) instead of
    // audio.duration. AVFoundation on macOS misreports fragmented MP4
    // duration (often doubled), which would otherwise let the 85% threshold
    // drift to ~170% of the real track length and never fire.
    final durationMs = expectedDuration.inMilliseconds;
    if (!_scored &&
        durationMs > 0 &&
        audio.position.inMilliseconds >= durationMs * .85) {
      _scored = true;
      unawaited(
        repository
            .score(current!)
            .catchError(
              (Object e) => message('Could not save listening history.'),
            ),
      );
    }
    if (_pendingListening >= 15000) unawaited(flushListening());
  }

  Future<void> flushListening() {
    final track = current;
    final amount = _pendingListening;
    if (track == null || amount <= 0) return _listeningWrite;
    _pendingListening = 0;
    final newPlay = _newListen;
    _newListen = false;
    final at = now();
    _listeningWrite = _listeningWrite
        .then((_) => repository.recordListening(track, amount, at, newPlay))
        .catchError((Object e) => message('Could not save listening history.'));
    return _listeningWrite;
  }

  Future<void> pause() async {
    ++_playId;
    resolvingAudio = false;
    loadingRecommendations = false;
    await audio.pause();
    await flushListening();
    _emit();
  }

  Future<void> refreshProfile({bool applySettings = false}) async {
    try {
      profile = await repository.profile();
      if (applySettings) {
        settings = profile.settings;
        volume = settings.volume;
        await audio.setVolume(volume);
        await audio.setSpeed(settings.speed);
      }
      _emit();
    } catch (e) {
      message('Could not load your library. ${_error(e)}');
    }
  }

  Future<void> _persistSettings() async {
    try {
      await repository.saveSettings(settings);
    } catch (e) {
      message('Could not save settings. ${_error(e)}');
    }
  }

  Future<void> updateSettings(AppSettings value) async {
    await flushListening();
    final old = settings;
    try {
      await audio.setSpeed(value.speed);
      if (audio.supportsEqualizer && current != null) {
        await audio.setEqualizer(value.equalizer);
      }
      await repository.saveSettings(value);
      settings = value;
      volume = value.volume;
      await audio.setVolume(volume);
      if (value.offline) {
        search('');
      }
      _emit();
    } catch (e) {
      await audio.setSpeed(old.speed);
      settings = old;
      message('Could not apply settings. ${_error(e)}');
    }
  }

  bool isLiked(Track track) => profile.liked.any((t) => t.id == track.id);
  bool isDownloaded(Track track) =>
      profile.downloads.any((r) => r.track.id == track.id);
  Future<void> toggleLike(Track track) => _mutation(() async {
    await repository.setLiked(track, !isLiked(track));
    await refreshProfile();
  });
  void openArtist(String name) {
    artist = name;
    page = MusicPage.artist;
    activePlaylistId = null;
    _emit();
  }

  List<Track> get artistTracks {
    final all = {
      for (final t in [
        ...searchTracks,
        ...profile.liked,
        ...profile.recent,
        ...profile.downloads.map((r) => r.track),
        ...songs,
        ...playlists.expand((p) => p.tracks),
      ])
        t.id: t,
    };
    return all.values.where((t) => t.artist == artist).toList();
  }

  void toggleShuffle() {
    shuffle = !shuffle;
    if (queue.isNotEmpty) {
      final played = queue.take(queueIndex + 1).toList();
      final remaining = queue.skip(queueIndex + 1).toList();
      if (shuffle) {
        remaining.shuffle(random);
      } else {
        remaining.sort(
          (a, b) => _originalQueue
              .indexWhere((t) => t.id == a.id)
              .compareTo(_originalQueue.indexWhere((t) => t.id == b.id)),
        );
      }
      queue = [...played, ...remaining];
    }
    _prepareNext();
    _emit();
  }

  Future<void> playQueueIndex(int index) async {
    if (index < 0 || index >= queue.length) return;
    queueIndex = index;
    await _start(queue[index]);
  }

  void addToQueue(Track track, {bool next = false}) {
    if (next) {
      queue.insert((queueIndex + 1).clamp(0, queue.length), track);
    } else {
      queue.add(track);
    }
    _originalQueue.add(track);
    _prepareNext();
    _emit();
    message(next ? 'Playing next: ${track.title}' : 'Added to queue.');
  }

  void removeQueueItem(int index) {
    if (index < 0 || index >= queue.length || index == queueIndex) return;
    queue.removeAt(index);
    if (index < queueIndex) queueIndex--;
    _prepareNext();
    _emit();
  }

  void reorderQueue(int from, int to) {
    if (from < 0 || from >= queue.length || to < 0 || to >= queue.length) {
      return;
    }
    final item = queue.removeAt(from);
    queue.insert(to, item);
    if (queueIndex == from) {
      queueIndex = to;
    } else if (from < queueIndex && to >= queueIndex) {
      queueIndex--;
    } else if (from > queueIndex && to <= queueIndex) {
      queueIndex++;
    }
    _prepareNext();
    _emit();
  }

  void clearUpcoming() {
    queue = queue.take(queueIndex + 1).toList();
    _prepareNext();
    _emit();
  }

  void setSleepTimer(Duration? duration, {bool afterTrack = false}) {
    _sleepTimer?.cancel();
    sleepAfterTrack = afterTrack;
    sleepUntil = duration == null ? null : now().add(duration);
    if (duration != null) {
      _sleepTimer = Timer(duration, () {
        sleepUntil = null;
        unawaited(pause());
        message('Sleep timer finished.');
      });
    }
    // End-of-track must receive a completion event rather than looping inside the player.
    if (afterTrack && loop) unawaited(setRepeat(RepeatMode.off));
    _emit();
  }

  Future<bool> editPlaylist(Playlist playlist) async {
    if (mutating) return false;
    mutating = true;
    _emit();
    try {
      _replace(await repository.editPlaylist(playlist));
      return true;
    } catch (e) {
      message(_error(e));
      return false;
    } finally {
      mutating = false;
      _emit();
    }
  }

  Future<void> duplicatePlaylist(Playlist playlist) => _mutation(() async {
    final created = await repository.createPlaylist('${playlist.name} (copy)');
    final copy = await repository.editPlaylist(
      created.copyWith(
        tracks: playlist.tracks,
        description: playlist.description,
      ),
    );
    playlists = [...playlists, copy];
    _emit();
  });
  Future<void> makePlaylist(String name, List<Track> tracks) =>
      _mutation(() async {
        final created = await repository.createPlaylist(name);
        final updated = await repository.editPlaylist(
          created.copyWith(tracks: tracks),
        );
        playlists = [...playlists, updated];
        openPlaylist(updated);
      });
  Future<void> deleteDownload(Track track) => _mutation(() async {
    if (current?.id == track.id && audio.playing) {
      message('Pause this song before removing its download.');
      return;
    }
    await repository.removeDownload(track.id);
    await refreshProfile();
  });
  Future<void> importAudio(String path, String name) => _mutation(() async {
    await repository.importAudio(path, name);
    await refreshProfile();
    message('Added to local files.');
  });
  Future<void> clearHistory() => _mutation(() async {
    await flushListening();
    await repository.clearHistory();
    _newListen = true;
    _scored = false;
    await refreshProfile();
    songs = [];
    _emit();
  });
  Future<void> importLibrary(String text) => _mutation(() async {
    await repository.importLibrary(text);
    await loadLibrary();
    message('Library imported.');
  });
  void setLibraryFilter(String text) {
    libraryFilter = text;
    _emit();
  }

  void setLibrarySort(String value) {
    librarySort = value;
    _emit();
  }

  List<Playlist> get visiblePlaylists {
    final lists = playlists
        .where(
          (p) => p.name.toLowerCase().contains(libraryFilter.toLowerCase()),
        )
        .toList();
    lists.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return switch (librarySort) {
        'name' => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        'size' => b.tracks.length.compareTo(a.tracks.length),
        _ => playlists.indexOf(b).compareTo(playlists.indexOf(a)),
      };
    });
    return lists;
  }

  @override
  void dispose() {
    _disposed = true;
    ++_searchId;
    ++_playId;
    ++_songsId;
    _debounce?.cancel();
    _prefetchTimer?.cancel();
    _sleepTimer?.cancel();
    _settingsTimer?.cancel();
    unawaited(flushListening());
    unawaited(_persistSettings());
    repository.dispose();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    playbackPosition.dispose();
    unawaited(audio.dispose());
    super.dispose();
  }
}
