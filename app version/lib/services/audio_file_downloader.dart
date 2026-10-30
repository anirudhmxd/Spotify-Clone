import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Downloads a resolved AAC/MP4 URL without another extractor invocation.
/// Range responses are checked before any bytes become an offline song.
class AudioFileDownloader {
  AudioFileDownloader({
    this.chunkSize = 512 * 1024,
    this.connections = 3,
    this.idleTimeout = const Duration(seconds: 8),
    this.totalTimeout = const Duration(minutes: 2),
  }) : assert(chunkSize >= 12),
       assert(connections > 0 && connections <= 4);

  final int chunkSize, connections;
  final Duration idleTimeout, totalTimeout;
  static const maxFileSize = 256 * 1024 * 1024;
  final Set<HttpClient> _clients = {};
  bool _disposed = false;

  Future<String> download(String url, File destination) async {
    if (_disposed) throw StateError('Downloader is closed.');
    final uri = Uri.parse(url);
    if (!['http', 'https'].contains(uri.scheme)) {
      throw ArgumentError('Invalid audio URL.');
    }
    final client = HttpClient()
      ..autoUncompress = false
      ..connectionTimeout = idleTimeout
      ..maxConnectionsPerHost = connections;
    _clients.add(client);
    final part = File('${destination.path}.fast.part');
    RandomAccessFile? file;
    var expired = false;
    final deadline = Timer(totalTimeout, () {
      expired = true;
      client.close(force: true);
    });
    try {
      await destination.parent.create(recursive: true);
      final first = await _request(client, uri, 0, chunkSize - 1);
      file = await part.open(mode: FileMode.write);
      if (first.statusCode == HttpStatus.ok) {
        // Servers without range support still use a single streamed transfer.
        final total = first.contentLength;
        _checkSize(total);
        var received = 0;
        await for (final bytes in first.timeout(idleTimeout)) {
          received += bytes.length;
          if (received > total) {
            throw const HttpException('Audio length changed.');
          }
          await file.writeFrom(bytes);
        }
        if (received != total) throw const HttpException('Incomplete audio.');
      } else {
        final total = _range(first, 0, chunkSize - 1);
        _checkSize(total);
        final firstBytes = await _bytes(first, min(total, chunkSize));
        _checkMp4(firstBytes);
        await file.truncate(total);
        await file.writeFrom(firstBytes);
        final validator =
            first.headers.value(HttpHeaders.etagHeader) ??
            first.headers.value(HttpHeaders.lastModifiedHeader);
        var offset = firstBytes.length;
        var failed = false;
        Future<void> writes = Future<void>.value();
        Future<void> worker() async {
          try {
            while (!failed && offset < total) {
              final start = offset;
              final end = min(total - 1, start + chunkSize - 1);
              offset = end + 1;
              Uint8List? bytes;
              for (var attempt = 0; attempt < 2; attempt++) {
                try {
                  final response = await _request(
                    client,
                    uri,
                    start,
                    end,
                    validator: validator,
                  );
                  if (_range(response, start, end) != total) {
                    throw const HttpException('Audio length changed.');
                  }
                  final actual =
                      response.headers.value(HttpHeaders.etagHeader) ??
                      response.headers.value(HttpHeaders.lastModifiedHeader);
                  if (validator != null && actual != validator) {
                    throw const HttpException('Audio changed during download.');
                  }
                  bytes = await _bytes(response, end - start + 1);
                  break;
                } on SocketException {
                  if (attempt == 1) rethrow;
                } on TimeoutException {
                  if (attempt == 1) rethrow;
                }
              }
              if (failed || bytes == null) return;
              // Network requests run concurrently; disk writes share one handle.
              final block = bytes;
              final write = writes.then((_) async {
                await file!.setPosition(start);
                await file!.writeFrom(block);
              });
              writes = write.then<void>(
                (_) {},
                onError: (Object _, StackTrace _) {},
              );
              await write;
            }
          } catch (_) {
            failed = true;
            client.close(force: true);
            rethrow;
          }
        }

        await Future.wait(List.generate(connections, (_) => worker()));
      }
      await file.close();
      file = null;
      if (_disposed || expired) {
        throw const HttpException('Download interrupted.');
      }
      _checkMp4(await part.openRead(0, 12).first);
      await part.rename(destination.path);
      return destination.path;
    } finally {
      deadline.cancel();
      client.close(force: true);
      _clients.remove(client);
      await file?.close();
      if (await part.exists()) await part.delete();
    }
  }

  Future<HttpClientResponse> _request(
    HttpClient client,
    Uri uri,
    int start,
    int end, {
    String? validator,
  }) async {
    final request = await client.getUrl(uri).timeout(idleTimeout);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    if (validator != null && !validator.startsWith('W/')) {
      request.headers.set(HttpHeaders.ifRangeHeader, validator);
    }
    return request.close().timeout(
      idleTimeout,
      onTimeout: () {
        request.abort();
        throw TimeoutException('Audio server did not respond.');
      },
    );
  }

  int _range(HttpClientResponse response, int start, int requestedEnd) {
    final match = RegExp(
      r'^bytes (\d+)-(\d+)/(\d+)$',
    ).firstMatch(response.headers.value(HttpHeaders.contentRangeHeader) ?? '');
    if (response.statusCode != HttpStatus.partialContent || match == null) {
      throw const HttpException('Server rejected the audio range.');
    }
    final total = int.parse(match[3]!);
    final end = min(requestedEnd, total - 1);
    if (int.parse(match[1]!) != start || int.parse(match[2]!) != end) {
      throw const HttpException('Server returned the wrong audio range.');
    }
    return total;
  }

  Future<Uint8List> _bytes(HttpClientResponse response, int expected) async {
    final result = BytesBuilder(copy: false);
    await for (final bytes in response.timeout(idleTimeout)) {
      result.add(bytes);
      if (result.length > expected) {
        throw const HttpException('Oversized audio range.');
      }
    }
    if (result.length != expected) {
      throw const HttpException('Incomplete audio range.');
    }
    return result.takeBytes();
  }

  void _checkSize(int length) {
    if (length < 12 || length > maxFileSize) {
      throw const HttpException('Invalid audio length.');
    }
  }

  void _checkMp4(List<int> bytes) {
    if (bytes.length < 12 ||
        bytes[4] != 0x66 ||
        bytes[5] != 0x74 ||
        bytes[6] != 0x79 ||
        bytes[7] != 0x70) {
      throw const HttpException('The server did not return MP4 audio.');
    }
  }

  void dispose() {
    _disposed = true;
    for (final client in _clients) {
      client.close(force: true);
    }
    _clients.clear();
  }
}
