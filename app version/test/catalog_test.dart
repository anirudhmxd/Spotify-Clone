import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythm_app/services/youtube_catalog.dart';
import 'package:ytdlp_flutter/ytdlp_flutter.dart';
import 'fakes.dart';
import 'package:rhythm_app/services/stream_resolver.dart';
import 'package:rhythm_app/services/audio_file_downloader.dart';

class _DirectDownloader extends AudioFileDownloader {
  final urls = <String>[];
  final started = Completer<void>();
  Completer<void>? release;
  bool fail = false;
  @override
  Future<String> download(String url, File destination) async {
    urls.add(url);
    if (!started.isCompleted) started.complete();
    await release?.future;
    if (fail) throw const HttpException('Expired URL');
    await destination.writeAsBytes([0, 0, 0, 24, 102, 116, 121, 112]);
    return destination.path;
  }
}

class _Downloader extends YtdlpPlatform {
  int calls = 0;
  bool fail = false;
  final started = Completer<void>();
  Completer<void>? release;
  @override
  Future<void> init() async {}
  @override
  Future<String> downloadAudio(
    String url,
    String outputDir, {
    required String taskId,
    String format = 'bestaudio/best',
    String? audioFormat,
    void Function(YtdlpProgress progress)? onProgress,
  }) async {
    calls++;
    if (!started.isCompleted) started.complete();
    if (release != null) await release!.future;
    if (fail) throw StateError('Temporary download error');
    final file = File('$outputDir/$taskId.m4a');
    await file.writeAsBytes([0, 0, 0, 24, 102, 116, 121, 112]);
    return file.path;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory dir;
  late YoutubeCatalog catalog;
  late YtdlpPlatform original;
  late _Downloader downloader;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('rhythm-audio-');
    original = YtdlpPlatform.instance;
    downloader = _Downloader();
    YtdlpPlatform.instance = downloader;
    catalog = YoutubeCatalog(
      cacheDirectory: () async => dir,
      streamResolver: StreamResolver(direct: (_) async => null),
    );
  });
  tearDown(() async {
    catalog.dispose();
    YtdlpPlatform.instance = original;
    await dir.delete(recursive: true);
  });
  test('download reuses prepared URL and skips native extraction', () async {
    catalog.dispose();
    final direct = _DirectDownloader();
    var lookups = 0;
    catalog = YoutubeCatalog(
      cacheDirectory: () async => dir,
      fileDownloader: direct,
      streamResolver: StreamResolver(
        direct: (_) async {
          lookups++;
          return 'https://audio.example/ready';
        },
      ),
    );
    await catalog.prepareAudio(song('seed0000001'));
    final path = await catalog.download(song('seed0000001'), dir);
    expect(await File(path).exists(), isTrue);
    expect(lookups, 1);
    expect(direct.urls, ['https://audio.example/ready']);
    expect(downloader.calls, 0);
    expect(await catalog.download(song('seed0000001'), dir), path);
    expect(direct.urls.length, 1);
  });
  test('a rejected direct URL falls back to native download', () async {
    catalog.dispose();
    final direct = _DirectDownloader()..fail = true;
    catalog = YoutubeCatalog(
      cacheDirectory: () async => dir,
      fileDownloader: direct,
      streamResolver: StreamResolver(
        direct: (_) async => 'https://audio.example/expired',
      ),
    );
    final path = await catalog.download(song('seed0000001'), dir);
    expect(await File(path).exists(), isTrue);
    expect(direct.urls.length, 1);
    expect(downloader.calls, 1);
  });
  test('concurrent download and playback share one direct transfer', () async {
    catalog.dispose();
    final direct = _DirectDownloader()..release = Completer<void>();
    var lookups = 0;
    catalog = YoutubeCatalog(
      cacheDirectory: () async => dir,
      fileDownloader: direct,
      streamResolver: StreamResolver(
        direct: (_) async {
          lookups++;
          return 'https://audio.example/ready';
        },
      ),
    );
    final download = catalog.download(song('seed0000001'), dir);
    await direct.started.future;
    final playback = catalog.resolveAudio(
      song('seed0000001'),
      preferDownload: true,
    );
    await catalog.prepareAudio(song('seed0000002'));
    direct.release!.complete();
    expect(await download, await playback);
    expect(lookups, 1);
    expect(direct.urls.length, 1);
    expect(downloader.calls, 0);
  });
  test(
    'failed download is removed from in-flight cache and can be retried',
    () async {
      downloader.fail = true;
      await expectLater(
        catalog.resolveAudio(song('seed0000001'), preferDownload: true),
        throwsStateError,
      );
      downloader.fail = false;
      final source = await catalog.resolveAudio(
        song('seed0000001'),
        preferDownload: true,
      );
      expect(await File(source).exists(), isTrue);
      expect(downloader.calls, 2);
    },
  );
  test(
    'simultaneous playback fallback and download share one request',
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
  test('prepare caches the stream and never downloads full media', () async {
    catalog.dispose();
    var calls = 0;
    catalog = YoutubeCatalog(
      cacheDirectory: () async => dir,
      streamResolver: StreamResolver(
        direct: (_) async {
          calls++;
          return 'https://audio.example/ready';
        },
      ),
    );
    await catalog.prepareAudio(song('seed0000001'));
    expect(
      await catalog.resolveAudio(song('seed0000001')),
      'https://audio.example/ready',
    );
    expect(calls, 1);
    expect(downloader.calls, 0);
  });
  test('failed preparation never starts a download', () async {
    catalog.dispose();
    catalog = YoutubeCatalog(
      cacheDirectory: () async => dir,
      streamResolver: StreamResolver(
        direct: (_) async => throw StateError('Unavailable'),
      ),
    );
    await catalog.prepareAudio(song('seed0000001'));
    expect(downloader.calls, 0);
  });
  test(
    'offline playback uses cached audio without a network request',
    () async {
      final cached = await File(
        '${dir.path}/seed0000001.m4a',
      ).writeAsBytes([0, 0, 0, 24, 102, 116]);
      expect(
        await catalog.resolveAudio(song('seed0000001'), offline: true),
        cached.path,
      );
      expect(downloader.calls, 0);
      await expectLater(
        catalog.resolveAudio(song('missing0001'), offline: true),
        throwsStateError,
      );
      expect(downloader.calls, 0);
    },
  );
}
