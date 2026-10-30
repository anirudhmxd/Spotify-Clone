import 'dart:async';
import 'package:rhythm_app/models/music.dart';
import 'package:rhythm_app/models/experience.dart';
import 'package:rhythm_app/services/audio_engine.dart';
import 'package:rhythm_app/services/music_repository.dart';

Track song(String id, [String? title]) => Track(
  id: id,
  title: title ?? id,
  artist: 'Test artist',
  album: 'Single',
  artwork: '',
  stream: '',
  durationMs: 180000,
  isMusic: true,
);

class FakeRepository implements MusicRepository {
  final searches = <String>[];
  final downloaded = <String>[];
  int profileReads = 0;
  Future<String> Function(Track)? onDownload;
  final resolutions = <bool>[];
  final prepared = <String>[];
  final refreshed = <String>[];
  final recommendationSeeds = <List<Track>>[];
  List<Track> recommendations = [];
  LibraryProfile data = const LibraryProfile();
  Future<SearchPage> Function(String, int)? onSearch;
  Future<String> Function(Track, bool)? onResolve;
  Future<List<Track>> Function(List<Track>)? onRecommend;
  @override
  Future<SearchPage> search(String query, int page) async {
    searches.add('$query/$page');
    return onSearch == null
        ? SearchPage([song('searchsong1', query)])
        : onSearch!(query, page);
  }

  @override
  void cancelSearch() {}
  @override
  Future<String> resolveAudio(
    Track track, {
    bool preferDownload = false,
    bool refreshStream = false,
  }) async {
    resolutions.add(preferDownload);
    if (refreshStream) refreshed.add(track.id);
    return onResolve == null
        ? 'file:///tmp/${track.id}.m4a'
        : onResolve!(track, preferDownload);
  }

  @override
  Future<List<Track>> recommend(List<Track> queue) async {
    recommendationSeeds.add([...queue]);
    return onRecommend == null ? recommendations : onRecommend!(queue);
  }

  @override
  Future<void> prepareAudio(Track track) async {
    prepared.add(track.id);
  }

  @override
  Future<List<Playlist>> playlists() async => [];
  @override
  Future<LibraryProfile> profile() async {
    profileReads++;
    return data;
  }

  @override
  Future<String> download(Track track) async {
    downloaded.add(track.id);
    final path =
        await (onDownload?.call(track) ?? Future.value('/tmp/${track.id}.m4a'));
    data = data.withDownloads([
      ...data.downloads,
      DownloadRecord(track: track, path: path, bytes: 100),
    ]);
    return path;
  }

  @override
  Future<void> saveSettings(AppSettings settings) async {}
  @override
  Future<void> rememberSearch(String term) async {}
  @override
  Future<void> recordListening(
    Track track,
    int milliseconds,
    DateTime at,
    bool newPlay,
  ) async {}
  @override
  Future<void> score(Track track) async {}
  @override
  void dispose() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeAudio implements AudioEngine {
  final ticks = StreamController<Duration>.broadcast(sync: true);
  final states = StreamController<void>.broadcast(sync: true);
  final completed = StreamController<void>.broadcast(sync: true);
  final files = <String>[];
  final urls = <String>[];
  bool failStream = false;
  Duration? clipEnd;
  @override
  bool playing = false;
  @override
  bool loading = false;
  @override
  Duration position = Duration.zero;
  @override
  Duration duration = const Duration(minutes: 3);
  @override
  bool get supportsEqualizer => false;
  @override
  Stream<Duration> get positions => ticks.stream;
  @override
  Stream<void> get changes => states.stream;
  @override
  Stream<void> get completions => completed.stream;
  void tick(Duration value) {
    position = value;
    ticks.add(value);
  }

  @override
  Future<void> load(String url, {Duration? end}) async {
    clipEnd = end;
    urls.add(url);
    if (failStream) throw StateError('Expired stream');
    position = Duration.zero;
  }

  @override
  Future<void> loadFile(String path, {Duration? end}) async {
    clipEnd = end;
    files.add(path);
    position = Duration.zero;
  }

  @override
  Future<void> play() async {
    playing = true;
    states.add(null);
  }

  @override
  Future<void> pause() async {
    playing = false;
    states.add(null);
  }

  @override
  Future<void> seek(Duration value) async => position = value;
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> setLoop(bool loop) async {}
  @override
  Future<void> setSpeed(double speed) async {}
  @override
  Future<void> setEqualizer(List<double> gains, {bool enabled = true}) async {}
  @override
  Future<List<double>> waveform({bool enabled = true}) async => [];
  @override
  Future<void> dispose() async {
    await ticks.close();
    await states.close();
    await completed.close();
  }
}
