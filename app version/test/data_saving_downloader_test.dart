import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:rhythm_app/services/data_saving_downloader.dart';

AudioOnlyStreamInfo audio(
  int tag,
  int bitrate, {
  String container = 'mp4',
  int size = 16,
}) => AudioOnlyStreamInfo.fromJson({
  'videoId': {'value': 'seed0000001'},
  'tag': tag,
  'url': 'https://audio.example/$tag',
  'container': {'name': container},
  'size': {'totalBytes': size},
  'bitrate': {'bitsPerSecond': bitrate},
  'audioCodec': container == 'mp4' ? 'mp4a.40.2' : 'opus',
  'codec': container == 'mp4' ? 'audio/mp4' : 'audio/webm',
  'qualityLabel': 'test',
  'fragments': [],
  'audioTrack': null,
});
final mp4 = [0, 0, 0, 16, 102, 116, 121, 112, 77, 52, 65, 32, 0, 0, 0, 0];
final webm = [0x1a, 0x45, 0xdf, 0xa3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];

class Client implements AudioDownloadClient {
  List<AudioOnlyStreamInfo> streams = [audio(140, 128000), audio(139, 48000)];
  Future<List<AudioOnlyStreamInfo>>? metadata;
  Stream<List<int>>? body;
  int? selected;
  bool closed = false;
  @override
  Future<List<AudioOnlyStreamInfo>> audioStreams(String id) async =>
      metadata ?? streams;
  @override
  Stream<List<int>> read(AudioOnlyStreamInfo info) {
    selected = info.tag;
    return body ?? Stream.fromIterable([mp4.sublist(0, 8), mp4.sublist(8)]);
  }

  @override
  void close() {
    closed = true;
  }
}

void main() {
  late Directory dir;
  late DataSavingDownloader downloader;
  late List<Client> clients;
  late Client Function() make;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('rhythm-data-saving-');
    clients = [];
    make = Client.new;
    downloader = DataSavingDownloader(
      clientFactory: () {
        final c = make();
        clients.add(c);
        return c;
      },
      appleCompatible: false,
    );
  });
  tearDown(() async {
    downloader.dispose();
    await dir.delete(recursive: true);
  });

  test('chooses the lowest bitrate explicitly, including WebM on Android', () {
    final streams = [
      audio(140, 128000),
      audio(139, 48000),
      audio(249, 32000, container: 'webm'),
    ];
    expect(
      DataSavingDownloader.selectAudio(streams, appleCompatible: false).tag,
      249,
    );
    expect(
      DataSavingDownloader.selectAudio(streams, appleCompatible: true).tag,
      139,
    );
    expect(
      () => DataSavingDownloader.selectAudio([
        streams.last,
      ], appleCompatible: true),
      throwsStateError,
    );
    expect(
      () => DataSavingDownloader.selectAudio([], appleCompatible: false),
      throwsStateError,
    );
  });
  test(
    'writes exact low-bitrate audio atomically and can download a second song',
    () async {
      for (final id in ['seed0000001', 'seed0000002']) {
        final file = await downloader.downloadSmallestAudio(id, directory: dir);
        expect(file.path, endsWith('/$id.m4a'));
        expect(await file.readAsBytes(), mp4);
      }
      expect(clients.length, 2);
      expect(clients.every((c) => c.closed && c.selected == 139), isTrue);
      expect((await dir.list().toList()).length, 2);
    },
  );
  test('preserves WebM container and extension', () async {
    make = () => Client()
      ..streams = [audio(249, 32000, container: 'webm')]
      ..body = Stream.value(webm);
    final file = await downloader.downloadSmallestAudio(
      'seed0000001',
      directory: dir,
    );
    expect(file.path, endsWith('.webm'));
    expect(await file.readAsBytes(), webm);
  });
  for (final body in [
    mp4.sublist(0, 8),
    [...mp4, 0],
    List.filled(16, 0),
  ]) {
    test(
      'incomplete, oversized and invalid responses do not become saved songs: ${body.length}',
      () async {
        make = () => Client()..body = Stream.value(body);
        await expectLater(
          downloader.downloadSmallestAudio('seed0000001', directory: dir),
          throwsA(isA<HttpException>()),
        );
        expect(await dir.list().toList(), isEmpty);
        expect(clients.single.closed, isTrue);
      },
    );
  }
  test('HTTP failures clean up and a later request can retry', () async {
    make = () => Client()..body = Stream.error(const HttpException('HTTP 403'));
    await expectLater(
      downloader.downloadSmallestAudio('seed0000001', directory: dir),
      throwsA(isA<HttpException>()),
    );
    make = Client.new;
    expect(
      await (await downloader.downloadSmallestAudio(
        'seed0000001',
        directory: dir,
      )).readAsBytes(),
      mp4,
    );
    expect(clients.every((c) => c.closed), isTrue);
  });
  test('source authorization errors are shown without signed URLs', () async {
    make = () => Client()
      ..body = Stream.error(
        FatalFailureException(
          'HTTP 403 https://audio.example/file?signature=SECRET',
          403,
        ),
      );
    await expectLater(
      downloader.downloadSmallestAudio('seed0000001', directory: dir),
      throwsA(
        isA<HttpException>().having(
          (e) => e.message,
          'message',
          allOf(contains('403'), isNot(contains('SECRET'))),
        ),
      ),
    );
    expect(await dir.list().toList(), isEmpty);
  });
  test('simultaneous requests share one manifest and transfer', () async {
    final body = StreamController<List<int>>();
    make = () => Client()..body = body.stream;
    final first = downloader.downloadSmallestAudio(
      'seed0000001',
      directory: dir,
    );
    final second = downloader.downloadSmallestAudio(
      'seed0000001',
      directory: dir,
    );
    await Future<void>.delayed(Duration.zero);
    body.add(mp4);
    await body.close();
    expect((await first).path, (await second).path);
    expect(clients.length, 1);
  });
  test('metadata timeout closes client without writing files', () async {
    downloader.dispose();
    final pending = Completer<List<AudioOnlyStreamInfo>>();
    final client = Client()..metadata = pending.future;
    downloader = DataSavingDownloader(
      clientFactory: () => client,
      metadataTimeout: const Duration(milliseconds: 20),
    );
    await expectLater(
      downloader.downloadSmallestAudio('seed0000001', directory: dir),
      throwsA(isA<TimeoutException>()),
    );
    pending.complete([]);
    expect(client.closed, isTrue);
    expect(await dir.list().toList(), isEmpty);
  });
  test('idle timeout cleans a partial file', () async {
    downloader.dispose();
    final body = StreamController<List<int>>();
    final client = Client()..body = body.stream;
    downloader = DataSavingDownloader(
      clientFactory: () => client,
      idleTimeout: const Duration(milliseconds: 20),
    );
    await expectLater(
      downloader.downloadSmallestAudio('seed0000001', directory: dir),
      throwsA(isA<TimeoutException>()),
    );
    await body.close();
    expect(client.closed, isTrue);
    expect(await dir.list().toList(), isEmpty);
  });
  test(
    'idle timeout stays bounded for a source that cannot cancel immediately',
    () async {
      downloader.dispose();
      final gate = Completer<void>();
      Stream<List<int>> blocked() async* {
        await gate.future;
        yield mp4;
      }

      final client = Client()..body = blocked();
      downloader = DataSavingDownloader(
        clientFactory: () => client,
        idleTimeout: const Duration(milliseconds: 20),
      );
      final clock = Stopwatch()..start();
      await expectLater(
        downloader.downloadSmallestAudio('seed0000001', directory: dir),
        throwsA(isA<TimeoutException>()),
      );
      expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
      expect(client.closed, isTrue);
      expect(await dir.list().toList(), isEmpty);
      gate.complete();
    },
  );
  test(
    'dispose cancels a stalled transfer and prevents later requests',
    () async {
      final body = StreamController<List<int>>();
      make = () => Client()..body = body.stream;
      final job = expectLater(
        downloader.downloadSmallestAudio('seed0000001', directory: dir),
        throwsStateError,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      downloader.dispose();
      await job;
      await body.close();
      expect(clients.single.closed, isTrue);
      expect(await dir.list().toList(), isEmpty);
      await expectLater(
        downloader.downloadSmallestAudio('seed0000002', directory: dir),
        throwsStateError,
      );
    },
  );
}
