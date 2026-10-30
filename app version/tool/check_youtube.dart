// Optional manual network check. No local service or external runtime is used.
import 'dart:io';
import 'package:rhythm_app/services/youtube_catalog.dart';

Future<void> main() async {
  final catalog = YoutubeCatalog();
  try {
    final page = await catalog.search('Beethoven Moonlight Sonata', 0);
    if (page.tracks.isEmpty) throw StateError('YouTube returned no results.');
    stdout.writeln('Direct search: ${page.tracks.length} tracks.');
    final track = page.tracks.first;
    final path = await catalog.resolveAudio(track);
    final file = File(path);
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
