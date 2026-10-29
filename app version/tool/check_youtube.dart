// Optional manual network check. No local service or external runtime is used.
import 'dart:io';
import 'package:spotify_app/services/youtube_catalog.dart';

Future<void> main() async {
  final catalog = YoutubeCatalog();
  try {
    final page = await catalog.search('Beethoven Moonlight Sonata', 0);
    if (page.tracks.isEmpty) throw StateError('YouTube returned no results.');
    stdout.writeln('Direct search: ${page.tracks.length} tracks.');
    final source = await catalog.resolveAudio(page.tracks.first);
    final uri = Uri.parse(source);
    if (uri.scheme != 'https' || !uri.host.endsWith('.googlevideo.com')) {
      throw StateError('Expected a direct HTTPS media URL.');
    }
    stdout.writeln('Direct audio resolution: passed.');
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await http.getUrl(uri);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != 200 && response.statusCode != 206) {
        throw StateError('Direct media returned HTTP ${response.statusCode}.');
      }
      final sample = await response.first.timeout(const Duration(seconds: 20));
      if (sample.isEmpty) throw StateError('Direct media was empty.');
      stdout.writeln('Direct audio byte delivery: passed.');
    } finally {
      http.close(force: true);
    }
  } finally {
    catalog.dispose();
  }
}
