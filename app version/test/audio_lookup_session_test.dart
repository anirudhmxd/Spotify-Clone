import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;
import 'package:rhythm_app/services/youtube_catalog.dart';
import 'package:rhythm_app/services/data_saving_downloader.dart';
import 'fakes.dart';

class _Streams extends Fake implements yt.StreamClient {
  final requested = <String>[];
  bool fail = false;
  Completer<void>? gate;
  @override
  Future<yt.StreamManifest> getManifest(
    dynamic videoId, {
    bool fullManifest = false,
    List<yt.YoutubeApiClient>? ytClients,
    bool requireWatchPage = true,
    bool audioOnly = false,
    bool validateStreams = true,
  }) async {
    expect(requireWatchPage, isFalse);
    expect(audioOnly, isTrue);
    expect(validateStreams, isFalse);
    requested.add(videoId.toString());
    if (fail) throw StateError('Failed metadata session');
    await gate?.future;
    return yt.StreamManifest([
      yt.AudioOnlyStreamInfo.fromJson({
        'videoId': {'value': videoId.toString()},
        'tag': 139,
        'url': 'https://audio.example/$videoId',
        'container': {'name': 'mp4'},
        'size': {'totalBytes': 100},
        'bitrate': {'bitsPerSecond': 48000},
        'audioCodec': 'mp4a.40.2',
        'codec': 'audio/mp4',
        'qualityLabel': 'low',
        'fragments': [],
        'audioTrack': null,
      }),
    ]);
  }
}

class _Videos extends Fake implements yt.VideoClient {
  _Videos(this.streamsClient);
  @override
  final yt.StreamClient streamsClient;
}

class _Client extends Fake implements yt.YoutubeExplode {
  final streams = _Streams();
  bool closed = false;
  @override
  late final yt.VideoClient videos = _Videos(streams);
  @override
  void close() {
    closed = true;
  }
}

class _NoDownload extends DataSavingDownloader {
  @override
  Future<File> downloadSmallestAudio(String id, {Directory? directory}) async =>
      throw StateError('No file fallback in this test');
}

void main() {
  late Directory dir;
  late YoutubeCatalog catalog;
  late List<_Client> clients;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('rhythm-lookup-session-');
    clients = [];
    catalog = YoutubeCatalog(
      cacheDirectory: () async => dir,
      downloader: _NoDownload(),
      audioClientFactory: () {
        final client = _Client();
        clients.add(client);
        return client;
      },
    );
  });
  tearDown(() async {
    catalog.dispose();
    await dir.delete(recursive: true);
  });
  test(
    'tracks share a live metadata session independent of search cancellation',
    () async {
      expect(
        await catalog.resolveAudio(song('seed0000001')),
        endsWith('/seed0000001'),
      );
      catalog.cancelSearch();
      expect(
        await catalog.resolveAudio(song('seed0000002')),
        endsWith('/seed0000002'),
      );
      expect(clients, hasLength(1));
      expect(clients.single.closed, isFalse);
      catalog.dispose();
      expect(clients.single.closed, isTrue);
    },
  );
  test('a failed session closes and is replaced for the next track', () async {
    await catalog.resolveAudio(song('seed0000001'));
    clients.single.streams.fail = true;
    await expectLater(
      catalog.resolveAudio(song('seed0000002')),
      throwsStateError,
    );
    expect(clients.first.closed, isTrue);
    expect(
      await catalog.resolveAudio(song('seed0000003')),
      endsWith('/seed0000003'),
    );
    expect(clients, hasLength(2));
    expect(clients.last.closed, isFalse);
  });
  test(
    'preparation is bounded to two unique tracks and shares pending playback',
    () async {
      await catalog.resolveAudio(song('seed0000001'));
      final streams = clients.single.streams..gate = Completer<void>();
      final first = catalog.prepareAudio(song('seed0000002'));
      final second = catalog.prepareAudio(song('seed0000003'));
      final duplicate = catalog.prepareAudio(song('seed0000002'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await catalog.prepareAudio(song('seed0000004'));
      final play = catalog.resolveAudio(song('seed0000003'));
      streams.gate!.complete();
      await Future.wait([first, second, duplicate]);
      expect(await play, endsWith('/seed0000003'));
      expect(
        streams.requested,
        unorderedEquals(['seed0000001', 'seed0000002', 'seed0000003']),
      );
    },
  );
}
