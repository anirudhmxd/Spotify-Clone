import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

import '../models/experience.dart';
import '../models/music.dart';
import 'data_saving_downloader.dart';

/// Downloads the original audio into a private workspace, then encodes MP3.
class YoutubeImporter {
  YoutubeImporter({
    Future<Track> Function(String)? metadata,
    Future<File> Function(String, Directory)? download,
    Future<void> Function(File, File)? encode,
  }) : _metadata = metadata ?? _fetchMetadata,
       _download = download ?? _fetchAudio,
       _encode = encode ?? _encodeMp3;

  final Future<Track> Function(String) _metadata;
  final Future<File> Function(String, Directory) _download;
  final Future<void> Function(File, File) _encode;

  static String videoId(String input) {
    final value = input.trim();
    final uri = Uri.tryParse(value.contains('://') ? value : 'https://$value');
    String? id;
    if (uri != null &&
        ['https', 'http'].contains(uri.scheme) &&
        uri.userInfo.isEmpty &&
        !uri.hasPort) {
      final host = uri.host.toLowerCase();
      final parts = uri.pathSegments;
      if (host == 'youtu.be' && parts.length == 1) {
        id = parts.first;
      } else if ([
        'youtube.com',
        'www.youtube.com',
        'm.youtube.com',
        'music.youtube.com',
      ].contains(host)) {
        if (uri.path == '/watch') {
          id = uri.queryParameters['v'];
        } else if (parts.length == 2 &&
            ['shorts', 'embed', 'live'].contains(parts.first)) {
          id = parts[1];
        }
      }
    }
    if (id == null || !RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id)) {
      throw ArgumentError('Enter a valid YouTube video link.');
    }
    return id;
  }

  // Stable local IDs preserve duplicate detection and local-only playback,
  // including for videos outside the music catalog.
  static String localId(String id) =>
      'local_${id.codeUnits.map((c) => c.toString().padLeft(3, '0')).join()}';

  Future<DownloadRecord> import(String url, Directory directory) async {
    final id = videoId(url);
    await directory.create(recursive: true);
    final workspace = await directory.createTemp('.youtube-');
    try {
      final metadata = await _metadata(id);
      final source = await _download(id, workspace);
      final output = File('${workspace.path}/output.mp3');
      await _encode(source, output);
      if (!await output.exists() || await output.length() == 0) {
        throw StateError('MP3 conversion produced no audio. Please try again.');
      }
      final file = await output.rename('${directory.path}/youtube_$id.mp3');
      return DownloadRecord(
        track: Track(
          id: localId(id),
          title: metadata.title,
          artist: metadata.artist,
          album: 'Imported from YouTube',
          artwork: metadata.artwork,
          stream: file.uri.toString(),
          durationMs: metadata.durationMs,
        ),
        path: file.path,
        bytes: await file.length(),
      );
    } finally {
      if (await workspace.exists()) await workspace.delete(recursive: true);
    }
  }

  static Future<Track> _fetchMetadata(String id) async {
    final client = yt.YoutubeExplode();
    try {
      final video = await client.videos
          .get(id)
          .timeout(const Duration(seconds: 30));
      if (video.isLive) throw StateError('Live videos cannot be imported.');
      return Track(
        id: id,
        title: video.title,
        artist: video.author,
        album: '',
        artwork: video.thumbnails.highResUrl,
        stream: '',
        durationMs: video.duration?.inMilliseconds ?? 0,
      );
    } finally {
      client.close();
    }
  }

  static Future<File> _fetchAudio(String id, Directory directory) async {
    final downloader = DataSavingDownloader(appleCompatible: false);
    try {
      return await downloader.downloadSmallestAudio(id, directory: directory);
    } finally {
      downloader.dispose();
    }
  }

  static Future<void> _encodeMp3(File input, File output) async {
    // Argument arrays preserve paths containing spaces and quotes.
    final session = await FFmpegKit.executeWithArguments([
      '-nostdin',
      '-y',
      '-i',
      input.path,
      '-map',
      '0:a:0',
      '-vn',
      '-c:a',
      'libmp3lame',
      '-b:a',
      '192k',
      '-f',
      'mp3',
      output.path,
    ]);
    if (!ReturnCode.isSuccess(await session.getReturnCode())) {
      throw StateError(
        'Could not convert this video to MP3. Please try again.',
      );
    }
  }
}
