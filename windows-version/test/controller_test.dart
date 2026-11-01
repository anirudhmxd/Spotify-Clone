import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythm/music_controller.dart';
import 'package:rhythm/models/music.dart';
import 'package:rhythm/services/music_repository.dart';
import 'fakes.dart';

Future<void> settle() => Future<void>.delayed(Duration.zero);
void main() {
  late FakeRepository repo;
  late FakeAudio audio;
  late MusicController c;
  setUp(() {
    repo = FakeRepository();
    audio = FakeAudio();
    c = MusicController(repo, audio);
  });
  tearDown(() => c.dispose());

  test(
    'repeated search reuses results and ignores an obsolete response',
    () async {
      final old = Completer<SearchPage>();
      repo.onSearch = (q, p) async =>
          q == 'old' ? old.future : SearchPage([song('newresult01', q)]);
      c.search('old', immediate: true);
      c.search('new', immediate: true);
      await settle();
      old.complete(SearchPage([song('oldresult01')]));
      await settle();
      expect(c.searchTracks.single.title, 'new');
      c.search('');
      c.search('new', immediate: true);
      await settle();
      expect(repo.searches.where((q) => q == 'new/0').length, 1);
      expect(c.searchTracks.single.title, 'new');
    },
  );

  test('search cache expires and pagination keeps unique songs', () async {
    var time = DateTime(2026);
    c.dispose();
    audio = FakeAudio();
    c = MusicController(repo, audio, now: () => time);
    repo.onSearch = (q, p) async => SearchPage(
      p == 0
          ? [song('result00001')]
          : [song('result00001'), song('result00002')],
      hasMore: p == 0,
    );
    c.search('music', immediate: true);
    await settle();
    await c.loadMore();
    expect(c.searchTracks.length, 2);
    time = time.add(const Duration(minutes: 6));
    c.search('music', immediate: true);
    await settle();
    expect(repo.searches.where((s) => s == 'music/0').length, 2);
  });

  test(
    'stream URLs start without downloading; blocked streams fall back',
    () async {
      repo.onResolve = (t, download) async =>
          download ? 'file:///tmp/song.m4a' : 'https://audio.example/song.m4a';
      await c.playTracks([song('song0000001')], 0);
      expect(audio.urls.length, 1);
      expect(audio.files, isEmpty);
      expect(repo.resolutions, [false]);
      audio.failStream = true;
      await c.playTracks([song('song0000002')], 0);
      expect(repo.resolutions, [false, false, false, true]);
      expect(repo.refreshed, ['song0000002']);
      expect(audio.files, ['/tmp/song.m4a']);
      expect(audio.playing, isTrue);
    },
  );

  test(
    'a fresh stream recovers playback without downloading the song',
    () async {
      var attempts = 0;
      repo.onResolve = (_, _) async {
        attempts++;
        if (attempts == 1) audio.failStream = true;
        if (attempts == 2) audio.failStream = false;
        return 'https://audio.example/attempt-$attempts';
      };
      await c.playTracks([song('seed0000001')], 0);
      expect(repo.refreshed, ['seed0000001']);
      expect(repo.resolutions, [false, false]);
      expect(audio.files, isEmpty);
      expect(audio.playing, isTrue);
    },
  );

  test('a late resolution cannot replace the newer selection', () async {
    final old = Completer<String>();
    repo.onResolve = (t, _) async =>
        t.id == 'song0000001' ? old.future : 'file:///tmp/new.m4a';
    final first = c.playTracks([song('song0000001')], 0);
    await settle();
    await c.playTracks([song('song0000002')], 0);
    old.complete('file:///tmp/old.m4a');
    await first;
    expect(audio.files, ['/tmp/new.m4a']);
    expect(c.current!.id, 'song0000002');
  });

  test(
    'cancel loading stays paused and a failed resolution can be retried',
    () async {
      final pending = Completer<String>();
      repo.onResolve = (t, _) => pending.future;
      final play = c.playTracks([song('song0000001')], 0);
      await settle();
      await c.togglePlay();
      pending.complete('file:///tmp/song.m4a');
      await play;
      expect(audio.files, isEmpty);
      expect(audio.playing, isFalse);
      repo.onResolve = (t, _) async => throw StateError('Temporary failure');
      await c.togglePlay();
      expect(c.resolvingAudio, isFalse);
      repo.onResolve = (t, _) async => 'file:///tmp/retry.m4a';
      await c.togglePlay();
      expect(audio.playing, isTrue);
    },
  );

  test(
    'search station queues recommendations instead of other search results',
    () async {
      final seed = song('seed0000001');
      final related = song('related0001');
      c.searchTracks = [seed, song('unrelated01')];
      repo.recommendations = [seed, related, related];
      await c.playRadio(seed);
      await settle();
      expect(c.queue.map((t) => t.id), [seed.id, related.id]);
      await c.next();
      expect(c.current!.id, related.id);
      expect(repo.recommendationSeeds.first.single.id, seed.id);
    },
  );

  test('late recommendations cannot change a new playlist', () async {
    final pending = Completer<List<Track>>();
    repo.onRecommend = (_) => pending.future;
    await c.playRadio(song('seed0000001'));
    await c.playTracks(
      [song('playlist001'), song('playlist002')],
      0,
      playlistId: 'p',
    );
    pending.complete([song('related0001')]);
    await settle();
    expect(c.queue.map((t) => t.id), ['playlist001', 'playlist002']);
    expect(c.loadingRecommendations, isFalse);
  });

  test('autoplay off preserves a single-song search queue', () async {
    c.settings = c.settings.copyWith(autoplay: false);
    await c.playRadio(song('seed0000001'));
    await c.next();
    expect(c.queue.length, 1);
    expect(repo.recommendationSeeds, isEmpty);
    expect(audio.playing, isFalse);
  });

  test(
    'position updates refresh progress without notifying the whole screen',
    () async {
      await c.playTracks([song('song0000001')], 0);
      var notifications = 0;
      c.addListener(() => notifications++);
      audio.tick(const Duration(seconds: 1));
      audio.tick(const Duration(seconds: 2));
      expect(c.playbackPosition.value, const Duration(seconds: 2));
      expect(notifications, 0);
    },
  );

  test(
    'Made for you uses the current song as its recommendation seed',
    () async {
      repo.recommendations = [song('related0001')];
      await c.playTracks([song('seed0000001')], 0);
      await c.loadSongs();
      expect(c.songs.single.id, 'related0001');
      expect(repo.recommendationSeeds.single.single.id, 'seed0000001');
    },
  );
  test('search, discovery and autoplay reject non-song candidates', () async {
    const video = Track(
      id: 'videotrack1',
      title: 'A video',
      artist: 'Test artist',
      album: '',
      artwork: '',
      stream: '',
    );
    repo.onSearch = (_, _) async => SearchPage([video, song('validsong01')]);
    c.search('test', immediate: true);
    await settle();
    expect(c.searchTracks.map((t) => t.id), ['validsong01']);
    repo.recommendations = [video, song('related0001')];
    await c.loadSongs();
    expect(c.songs.map((t) => t.id), ['related0001']);
    await c.playRadio(song('seed0000001'));
    await settle();
    expect(c.queue.map((t) => t.id), ['seed0000001', 'related0001']);
    c.clearUpcoming();
    await c.next();
    expect(c.current!.id, 'related0001');
    expect(c.queue.every((t) => t.isSong), isTrue);
  });
}
