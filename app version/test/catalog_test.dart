import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythm_app/services/youtube_catalog.dart';
import 'package:rhythm_app/services/data_saving_downloader.dart';
import 'package:rhythm_app/services/stream_resolver.dart';
import 'fakes.dart';

class _Downloader extends DataSavingDownloader {
  int calls = 0;
  bool fail = false;
  final started = Completer<void>();
  Completer<void>? release;
  @override
  Future<File> downloadSmallestAudio(String id, {Directory? directory}) async {
    calls++;
    if (!started.isCompleted) started.complete();
    await release?.future;
    if (fail) throw const HttpException('Audio request rejected');
    return File(
      '${directory!.path}/$id.m4a',
    ).writeAsBytes([0, 0, 0, 24, 102, 116, 121, 112]);
  }
}

void main() {
  late Directory dir;
  late YoutubeCatalog catalog;
  late _Downloader downloader;
  var lookups = 0;
  setUp(() async {
    lookups = 0;
    dir = await Directory.systemTemp.createTemp('rhythm-catalog-');
    downloader = _Downloader();
    catalog = YoutubeCatalog(
      cacheDirectory: () async => dir,
      downloader: downloader,
      streamResolver: StreamResolver(
        direct: (_) async {
          lookups++;
          return 'https://audio.example/ready';
        },
      ),
    );
  });
  tearDown(() async {
    catalog.dispose();
    await dir.delete(recursive: true);
  });

  test(
    'explicit download uses the library downloader and reuses the finished file',
    () async {
      final path = await catalog.download(song('seed0000001'), dir);
      expect(await File(path).exists(), isTrue);
      expect(await catalog.download(song('seed0000001'), dir), path);
      expect(downloader.calls, 1);
      expect(lookups, 0);
    },
  );
  test(
    'rejected playback switches to library bytes without retrying the playback URL',
    () async {
      final track = song('seed0000001');
      expect(await catalog.resolveAudio(track), startsWith('https:'));
      final path = await catalog.resolveAudio(track, refreshStream: true);
      expect(await File(path).exists(), isTrue);
      expect(downloader.calls, 1);
      expect(lookups, 1);
    },
  );
  test(
    'failed stream lookup falls back once to the library downloader',
    () async {
      catalog.dispose();
      catalog = YoutubeCatalog(
        cacheDirectory: () async => dir,
        downloader: downloader,
        streamResolver: StreamResolver(
          direct: (_) async {
            lookups++;
            throw StateError('No stream');
          },
        ),
      );
      final path = await catalog.resolveAudio(song('seed0000001'));
      expect(await File(path).exists(), isTrue);
      expect(lookups, 1);
      expect(downloader.calls, 1);
    },
  );
  test(
    'simultaneous playback fallback and download share one transfer',
    () async {
      downloader.release = Completer<void>();
      final playback = catalog.resolveAudio(
        song('seed0000001'),
        preferDownload: true,
      );
      await downloader.started.future;
      final download = catalog.download(song('seed0000001'), dir);
      downloader.release!.complete();
      expect(await playback, await download);
      expect(downloader.calls, 1);
    },
  );
  test('failed downloads remain retryable', () async {
    downloader.fail = true;
    await expectLater(
      catalog.download(song('seed0000001'), dir),
      throwsA(isA<HttpException>()),
    );
    downloader.fail = false;
    expect(
      await File(await catalog.download(song('seed0000001'), dir)).exists(),
      isTrue,
    );
    expect(downloader.calls, 2);
  });
  test('preparation caches a URL and never downloads full audio', () async {
    await catalog.prepareAudio(song('seed0000001'));
    await catalog.resolveAudio(song('seed0000001'));
    expect(lookups, 1);
    expect(downloader.calls, 0);
  });
  test('offline playback never contacts either network path', () async {
    final file = await File(
      '${dir.path}/seed0000001.m4a',
    ).writeAsBytes([1, 2, 3]);
    expect(
      await catalog.resolveAudio(song('seed0000001'), offline: true),
      file.path,
    );
    await expectLater(
      catalog.resolveAudio(song('missing0001'), offline: true),
      throwsStateError,
    );
    expect(lookups, 0);
    expect(downloader.calls, 0);
  });
}
