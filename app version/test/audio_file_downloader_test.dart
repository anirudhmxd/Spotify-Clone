import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythm_app/services/audio_file_downloader.dart';

class _LiveHttp extends HttpOverrides {}

void main() {
  late HttpServer server;
  late Directory directory;
  late File destination;
  late AudioFileDownloader downloader;
  final bytes = Uint8List.fromList(List.generate(4097, (i) => i % 251))
    ..setRange(4, 8, [102, 116, 121, 112]);
  var active = 0, peak = 0, requests = 0;
  var mode = 'range';
  late Completer<void> started;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('rhythm-download-test-');
    destination = File('${directory.path}/song.m4a');
    downloader = AudioFileDownloader(chunkSize: 512);
    active = peak = requests = 0;
    mode = 'range';
    started = Completer<void>();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      active++;
      requests++;
      peak = max(peak, active);
      if (!started.isCompleted) started.complete();
      try {
        if (mode == 'stall') {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
        if (mode == 'denied' ||
            (mode == 'later_and_full_denied' &&
                request.headers.value(HttpHeaders.rangeHeader) == null)) {
          request.response.statusCode = 403;
          return;
        }
        if (mode == 'full' ||
            mode == 'html' ||
            (mode == 'later_denied' &&
                request.headers.value(HttpHeaders.rangeHeader) == null)) {
          final body = mode == 'html' ? List.filled(100, 65) : bytes;
          request.response.contentLength = body.length;
          request.response.add(body);
          return;
        }
        final match = RegExp(
          r'bytes=(\d+)-(\d+)',
        ).firstMatch(request.headers.value(HttpHeaders.rangeHeader)!)!;
        final start = int.parse(match[1]!);
        final end = min(int.parse(match[2]!), bytes.length - 1);
        if (start > 0 &&
            ['later_denied', 'later_and_full_denied'].contains(mode)) {
          request.response.statusCode = 403;
          return;
        }
        request.response.statusCode = 206;
        request.response.headers.set(
          'Content-Range',
          'bytes ${mode == 'wrong' && start > 0 ? 0 : start}-$end/${bytes.length}',
        );
        request.response.headers.set(
          'ETag',
          mode == 'changed' && start > 0 ? '"new"' : '"original"',
        );
        final payload = bytes.sublist(start, end + 1);
        request.response.add(
          mode == 'short' && start > 0
              ? payload.sublist(0, payload.length - 1)
              : payload,
        );
      } catch (_) {
        // Timeout/disposal tests intentionally disconnect the client.
      } finally {
        active--;
        try {
          await request.response.close();
        } catch (_) {}
      }
    });
  });
  tearDown(() async {
    downloader.dispose();
    await server.close(force: true);
    await directory.delete(recursive: true);
  });
  Future<String> download() => HttpOverrides.runWithHttpOverrides(
    () => downloader.download(
      'http://127.0.0.1:${server.port}/song',
      destination,
    ),
    _LiveHttp(),
  );
  test('concurrent ranges produce a byte-perfect complete file', () async {
    final pending = download();
    await started.future;
    expect(await destination.exists(), isFalse);
    expect(await pending, destination.path);
    expect(await destination.readAsBytes(), bytes);
    expect(peak, 3);
    expect(requests, 9);
    expect(await File('${destination.path}.fast.part').exists(), isFalse);
  });
  test(
    'later 403 falls back to one complete transfer with identical bytes',
    () async {
      mode = 'later_denied';
      await download();
      expect(await destination.readAsBytes(), bytes);
      expect(await File('${destination.path}.fast.part').exists(), isFalse);
    },
  );
  test(
    'rejected complete-transfer fallback cleans up and remains retryable',
    () async {
      mode = 'later_and_full_denied';
      await expectLater(download(), throwsA(isA<HttpException>()));
      expect(await directory.list().toList(), isEmpty);
      mode = 'full';
      await download();
      expect(await destination.readAsBytes(), bytes);
    },
  );
  test('a server ignoring Range is downloaded with one request', () async {
    mode = 'full';
    await download();
    expect(await destination.readAsBytes(), bytes);
    expect(requests, 1);
  });
  for (final failure in ['denied', 'wrong', 'short', 'changed', 'html']) {
    test('$failure responses never become an offline song', () async {
      mode = failure;
      await expectLater(download(), throwsA(isA<HttpException>()));
      expect(await directory.list().toList(), isEmpty);
    });
  }
  test('a stalled transfer times out and removes partial data', () async {
    mode = 'stall';
    downloader.dispose();
    downloader = AudioFileDownloader(
      idleTimeout: const Duration(milliseconds: 30),
    );
    await expectLater(download(), throwsA(isA<TimeoutException>()));
    expect(await directory.list().toList(), isEmpty);
  });
  test(
    'disposing cancels active requests without leaving partial songs',
    () async {
      mode = 'stall';
      final pending = expectLater(download(), throwsA(anything));
      await started.future;
      downloader.dispose();
      await pending;
      expect(await directory.list().toList(), isEmpty);
      await expectLater(download(), throwsStateError);
    },
  );
}
