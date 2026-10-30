import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythm_app/services/youtube_catalog.dart';
import 'package:ytdlp_flutter/ytdlp_flutter.dart';
import 'fakes.dart';

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
    catalog = YoutubeCatalog(cacheDirectory: () async => dir);
  });
  tearDown(() async {
    catalog.dispose();
    YtdlpPlatform.instance = original;
    await dir.delete(recursive: true);
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
