import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythm_app/models/music.dart';
import 'package:rhythm_app/models/experience.dart';
import 'package:rhythm_app/services/device_music_repository.dart';
import 'package:rhythm_app/services/library_store.dart';
import 'package:rhythm_app/services/music_repository.dart';
import 'package:rhythm_app/services/youtube_catalog.dart';
import 'fakes.dart';

class FakeCatalog implements MusicCatalog {
  List<Track> results = [];
  int relatedCalls = 0;
  bool fail = false;
  String source = 'https://audio.example/song.m4a';
  @override
  Future<List<Track>> related(Track seed) async {
    relatedCalls++;
    if (fail) throw StateError('Offline');
    return results;
  }

  @override
  Future<String> resolveAudio(
    Track track, {
    bool offline = false,
    bool preferDownload = false,
  }) async => source;
  @override
  void dispose() {}
  @override
  void cancelSearch() {}
  @override
  Future<SearchPage> search(String query, int page) async =>
      const SearchPage([]);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory dir;
  late LibraryStore store;
  late FakeCatalog catalog;
  late DeviceMusicRepository repo;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('rhythm-tests-');
    store = LibraryStore(directory: () async => dir);
    catalog = FakeCatalog();
    repo = DeviceMusicRepository(
      store: store,
      catalog: catalog,
      documents: () async => dir,
    );
  });
  tearDown(() async {
    repo.dispose();
    await dir.delete(recursive: true);
  });

  test(
    'recommendations use related music and exclude duplicate editions',
    () async {
      final seed = song('seed0000001', 'A favourite (Official Audio)');
      catalog.results = [
        seed,
        song('duplicate01', 'A favourite [Lyrics]'),
        song('related0001', 'A new discovery'),
        song('related0001', 'A new discovery'),
      ];
      final result = await repo.recommend([seed]);
      expect(result.map((t) => t.id), ['related0001']);
      expect(catalog.relatedCalls, 1);
    },
  );

  test('liked songs seed discovery before a completed listen', () async {
    await store.setLiked(song('seed0000001'), true);
    catalog.results = [song('related0001')];
    expect((await repo.recommend([])).single.id, 'related0001');
  });

  test('recommendation outages use related local library tracks', () async {
    catalog.fail = true;
    await store.setLiked(song('related0001'), true);
    expect(
      (await repo.recommend([song('seed0000001')])).single.id,
      'related0001',
    );
  });

  test(
    'offline recommendations only include downloaded songs without network',
    () async {
      await store.setLiked(song('notdownload'), true);
      await store.saveDownload(
        DownloadRecord(
          track: song('download001'),
          path: '${dir.path}/song.m4a',
          bytes: 3,
        ),
      );
      await repo.saveSettings(const AppSettings(offline: true));
      expect(
        (await repo.recommend([song('seed0000001')])).single.id,
        'download001',
      );
      expect(catalog.relatedCalls, 0);
    },
  );

  test(
    'stream URLs survive the repository; local paths become file URIs',
    () async {
      expect(await repo.resolveAudio(song('seed0000001')), catalog.source);
      catalog.source = '${dir.path}/song.m4a';
      expect(
        await repo.resolveAudio(song('seed0000001')),
        File(catalog.source).uri.toString(),
      );
    },
  );

  test('cache lookup ignores incomplete download files', () async {
    await File('${dir.path}/seed0000001.m4a.part').writeAsBytes([1, 2, 3]);
    await File('${dir.path}/seed0000001.info.json').writeAsString('{}');
    expect(await YoutubeCatalog.cachedFile(dir, 'seed0000001'), isNull);
    final audio = await File(
      '${dir.path}/seed0000001.m4a',
    ).writeAsBytes([0, 0, 0, 1, 2, 3]);
    expect(
      (await YoutubeCatalog.cachedFile(dir, 'seed0000001'))!.path,
      audio.path,
    );
  });
}
