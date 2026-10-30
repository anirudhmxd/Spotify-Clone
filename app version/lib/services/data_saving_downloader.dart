import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'audio_diagnostics.dart';

/// A fresh client owns each manifest/transfer pair and closes after that job.
abstract class AudioDownloadClient {
  Future<List<AudioOnlyStreamInfo>> audioStreams(String id);
  Stream<List<int>> read(AudioOnlyStreamInfo stream);
  void close();
}

class YoutubeAudioDownloadClient implements AudioDownloadClient {
  final YoutubeExplode _yt = YoutubeExplode();
  @override
  Future<List<AudioOnlyStreamInfo>> audioStreams(String id) async =>
      (await _yt.videos.streamsClient.getManifest(id)).audioOnly.toList();
  @override
  Stream<List<int>> read(AudioOnlyStreamInfo stream) =>
      _yt.videos.streamsClient.get(stream);
  @override
  void close() => _yt.close();
}

class DataSavingDownloader {
  DataSavingDownloader({
    AudioDownloadClient Function()? clientFactory,
    bool? appleCompatible,
    this.metadataTimeout = const Duration(seconds: 15),
    this.idleTimeout = const Duration(seconds: 10),
    this.totalTimeout = const Duration(minutes: 2),
  }) : _clientFactory = clientFactory ?? YoutubeAudioDownloadClient.new,
       _appleCompatible =
           appleCompatible ?? (Platform.isIOS || Platform.isMacOS);

  final AudioDownloadClient Function() _clientFactory;
  final bool _appleCompatible;
  final Duration metadataTimeout, idleTimeout, totalTimeout;
  final _jobs = <String, Future<File>>{};
  final _clients = <AudioDownloadClient, StreamIterator<List<int>>?>{};
  bool _disposed = false;

  /// Lowest bitrate first; preserve the actual container instead of relabelling it.
  static AudioOnlyStreamInfo selectAudio(
    Iterable<AudioOnlyStreamInfo> streams, {
    required bool appleCompatible,
  }) {
    final candidates =
        streams
            .where(
              (stream) =>
                  stream.size.totalBytes > 0 &&
                  (stream.container.name == 'mp4' ||
                      (!appleCompatible && stream.container.name == 'webm')),
            )
            .toList()
          ..sort((a, b) {
            final bitrate = a.bitrate.compareTo(b.bitrate);
            return bitrate != 0
                ? bitrate
                : a.size.totalBytes.compareTo(b.size.totalBytes);
          });
    if (candidates.isEmpty) {
      throw StateError(
        'No compatible audio-only stream is available for this song.',
      );
    }
    return candidates.first;
  }

  Future<File> downloadSmallestAudio(
    String videoUrl, {
    Directory? directory,
  }) async {
    if (_disposed) throw StateError('Audio downloader is closed.');
    // Existing catalog metadata already supplies the video ID/title. No extra videos.get.
    final id = VideoId.fromString(videoUrl).value;
    final dir =
        directory ??
        (Platform.isAndroid ? await getExternalStorageDirectory() : null) ??
        await getApplicationDocumentsDirectory();
    _checkActive(false);
    final key = '${dir.path}/$id';
    final pending = _jobs[key];
    if (pending != null) return pending;
    final job = _download(id, dir);
    _jobs[key] = job;
    try {
      return await job;
    } finally {
      _jobs.remove(key);
    }
  }

  Future<File> _download(String id, Directory directory) async {
    final client = _clientFactory();
    _clients[client] = null;
    final clock = Stopwatch()..start();
    var expired = false;
    final deadline = Timer(totalTimeout, () {
      expired = true;
      client.close();
      unawaited(_clients[client]?.cancel());
    });
    File? part;
    RandomAccessFile? output;
    StreamIterator<List<int>>? iterator;
    var received = 0, lastProgress = -2000;
    try {
      AudioDiagnostics.log(
        'download.manifest_start',
        'track=$id provider=youtube_explode',
      );
      final streams = await client.audioStreams(id).timeout(metadataTimeout);
      _checkActive(expired);
      final selected = selectAudio(streams, appleCompatible: _appleCompatible);
      final expected = selected.size.totalBytes;
      if (expected > 256 * 1024 * 1024) {
        throw StateError('Audio file is too large.');
      }
      final extension = selected.container.name == 'mp4' ? 'm4a' : 'webm';
      AudioDiagnostics.log(
        'download.selected',
        'track=$id ms=${clock.elapsedMilliseconds} bitrate=${selected.bitrate.bitsPerSecond} bytes=$expected container=$extension',
      );
      await directory.create(recursive: true);
      final destination = File('${directory.path}/$id.$extension');
      part = File('${destination.path}.part');
      output = await part.open(mode: FileMode.write);
      iterator = StreamIterator(client.read(selected));
      _clients[client] = iterator;
      while (await iterator.moveNext().timeout(
        idleTimeout,
        onTimeout: () {
          client.close();
          // StreamIterator may await an async generator's cancellation. Bound
          // the wait outside the stream so an unresponsive source cannot hang it.
          unawaited(iterator!.cancel().catchError((Object _) {}));
          throw TimeoutException('Audio stream stopped responding.');
        },
      )) {
        _checkActive(expired);
        final bytes = iterator.current;
        received += bytes.length;
        if (received > expected) {
          throw const HttpException(
            'Audio response exceeds its expected length.',
          );
        }
        await output.writeFrom(bytes);
        final elapsed = clock.elapsedMilliseconds;
        if (elapsed - lastProgress >= 2000) {
          lastProgress = elapsed;
          AudioDiagnostics.log(
            'download.progress',
            'track=$id ms=$elapsed bytes=$received total=$expected',
          );
        }
      }
      _checkActive(expired);
      if (received != expected) {
        throw const HttpException('The audio download is incomplete.');
      }
      await output.close();
      output = null;
      final header = await part.openRead(0, 12).first;
      final valid = extension == 'm4a'
          ? header.length >= 8 &&
                header[4] == 102 &&
                header[5] == 116 &&
                header[6] == 121 &&
                header[7] == 112
          : header.length >= 4 &&
                header[0] == 0x1a &&
                header[1] == 0x45 &&
                header[2] == 0xdf &&
                header[3] == 0xa3;
      if (!valid) throw const HttpException('The response is not valid audio.');
      _checkActive(expired);
      final file = await part.rename(destination.path);
      AudioDiagnostics.log(
        'download.complete',
        'track=$id ms=${clock.elapsedMilliseconds} bytes=$received provider=youtube_explode',
      );
      return file;
    } catch (error) {
      AudioDiagnostics.log(
        'download.failed',
        'track=$id ms=${clock.elapsedMilliseconds} bytes=$received error=$error',
      );
      if (error is FatalFailureException) {
        throw HttpException(
          'YouTube refused this audio stream (HTTP ${error.statusCode}). Please try again later.',
        );
      }
      rethrow;
    } finally {
      deadline.cancel();
      client.close();
      _clients.remove(client);
      try {
        await iterator?.cancel().timeout(const Duration(seconds: 1));
      } catch (_) {}
      await output?.close();
      if (part != null && await part.exists()) await part.delete();
    }
  }

  void _checkActive(bool expired) {
    if (_disposed) throw StateError('Audio downloader is closed.');
    if (expired) throw TimeoutException('Audio download timed out.');
  }

  void dispose() {
    _disposed = true;
    for (final entry in _clients.entries.toList()) {
      entry.key.close();
      unawaited(entry.value?.cancel().catchError((Object _) {}));
    }
  }
}
