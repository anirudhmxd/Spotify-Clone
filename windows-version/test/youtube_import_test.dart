import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythm/models/music.dart';
import 'package:rhythm/music_controller.dart';
import 'package:rhythm/services/device_music_repository.dart';
import 'package:rhythm/services/library_store.dart';
import 'package:rhythm/services/youtube_importer.dart';
import 'package:rhythm/widgets/youtube_import_button.dart';
import 'fakes.dart';
import 'repository_test.dart' show FakeCatalog;

const videoId = 'dQw4w9WgXcQ';
const link = 'https://youtu.be/$videoId';
const metadata = Track(
  id: videoId,
  title: 'Imported video',
  artist: 'Creator',
  album: '',
  artwork: '',
  stream: '',
  durationMs: 10000,
);

class ImportRepository extends FakeRepository {
  int calls = 0;
  final complete = Completer<Track>();
  @override
  Future<Track> importYoutube(String url) {
    calls++;
    return complete.future;
  }
}

void main() {
  test(
    'accepts supported YouTube links and rejects unrelated hosts and playlists',
    () {
      for (final url in [
        link,
        'youtube.com/watch?v=$videoId&list=abc',
        'https://music.youtube.com/watch?v=$videoId',
        'https://www.youtube.com/shorts/$videoId',
        'https://m.youtube.com/embed/$videoId',
      ]) {
        expect(YoutubeImporter.videoId(url), videoId);
      }
      for (final url in [
        '',
        videoId,
        'https://youtube.com.evil.test/watch?v=$videoId',
        'https://example.com/$videoId',
        'https://youtube.com/playlist?list=abc',
        'file:///watch?v=$videoId',
        'https://youtube.com/watch?v=bad',
      ]) {
        expect(() => YoutubeImporter.videoId(url), throwsArgumentError);
      }
    },
  );

  late Directory dir;
  setUp(
    () async => dir = await Directory.systemTemp.createTemp('youtube-import-'),
  );
  tearDown(() async => dir.delete(recursive: true));

  YoutubeImporter importer({bool fail = false, void Function()? onDownload}) =>
      YoutubeImporter(
        metadata: (_) async => metadata,
        download: (_, workspace) async {
          onDownload?.call();
          return File('${workspace.path}/source.webm').writeAsBytes([1, 2, 3]);
        },
        encode: (_, output) async {
          await output.writeAsBytes([73, 68, 51, 1, 2, 3]);
          if (fail) throw StateError('conversion failed');
        },
      );

  test(
    'saves MP3 metadata in library, deduplicates, and plays offline',
    () async {
      var downloads = 0;
      final repo = DeviceMusicRepository(
        store: LibraryStore(directory: () async => dir),
        catalog: FakeCatalog()..directory = dir,
        documents: () async => dir,
        youtubeImporter: importer(onDownload: () => downloads++),
      );
      addTearDown(repo.dispose);
      final track = await repo.importYoutube(link);
      expect(track.title, metadata.title);
      final profile = await repo.profile();
      expect(profile.downloads.single.path, endsWith('.mp3'));
      expect(profile.downloads.single.bytes, 6);
      expect(await repo.importYoutube(link), isA<Track>());
      expect(downloads, 1);
      await repo.saveSettings(profile.settings.copyWith(offline: true));
      expect(await repo.resolveAudio(track), startsWith('file:'));
      await expectLater(repo.importYoutube(link), throwsStateError);
      await repo.removeDownload(track.id);
      expect((await repo.profile()).downloads, isEmpty);
    },
  );

  test(
    'conversion failure leaves no partial files or library records',
    () async {
      final repo = DeviceMusicRepository(
        store: LibraryStore(directory: () async => dir),
        catalog: FakeCatalog()..directory = dir,
        documents: () async => dir,
        youtubeImporter: importer(fail: true),
      );
      addTearDown(repo.dispose);
      await expectLater(repo.importYoutube(link), throwsStateError);
      expect(await Directory('${dir.path}/imports').list().toList(), isEmpty);
      expect((await repo.profile()).downloads, isEmpty);
    },
  );

  testWidgets(
    'form validates links and prevents duplicate submissions while busy',
    (tester) async {
      final repo = ImportRepository();
      final controller = MusicController(repo, FakeAudio());
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: YoutubeImportButton(controller: controller)),
        ),
      );
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('Import from YouTube'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('Download MP3'));
      await tester.pump();
      expect(find.text('Enter a valid YouTube video link.'), findsOneWidget);
      expect(repo.calls, 0);
      await tester.enterText(find.byType(TextField), link);
      await tester.tap(find.text('Download MP3'));
      await tester.pump();
      expect(find.text('Downloading and converting…'), findsOneWidget);
      expect(repo.calls, 1);
      repo.complete.complete(metadata);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Import from YouTube'), findsOneWidget);
    },
  );
}
