// Manual check for a Flutter host with registered native plugins.
// For the automated network check use tool/catalog_live_test.dart.
import 'dart:io';
import 'package:rhythm/services/youtube_catalog.dart';

Future<void> main() async {
  final catalog = YoutubeCatalog();
  try {
    final page = await catalog.search('Beethoven Moonlight Sonata', 0);
    if (page.tracks.isEmpty) throw StateError('YouTube returned no results.');
    stdout.writeln('Direct search: ${page.tracks.length} tracks.');
    final track = page.tracks.first;
    final source = await catalog.resolveAudio(track);
    final uri = Uri.parse(source);
    if (uri.scheme == 'https' || uri.scheme == 'http') {
      stdout.writeln('Direct stream resolved successfully.');
      return;
    }
    final file = uri.scheme == 'file' ? File.fromUri(uri) : File(source);
    if (!await file.exists() || await file.length() == 0) {
      throw StateError('Resolved audio is missing or empty.');
    }
    stdout.writeln(
      'Local audio resolution: passed (${file.path}, ${await file.length()} bytes).',
    );
  } finally {
    catalog.dispose();
  }
}
