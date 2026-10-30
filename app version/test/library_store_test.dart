import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythm_app/services/library_store.dart';
import 'fakes.dart';

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('rhythm-library-');
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });
  test(
    'repeated reads use one snapshot and writes survive reopening',
    () async {
      var lookups = 0;
      final store = LibraryStore(
        directory: () async {
          lookups++;
          return dir;
        },
      );
      await store.setLiked(song('seed0000001'), true);
      await store.rememberSearch('Hip hop music');
      final first = await store.profile();
      first.searches.clear();
      expect((await store.profile()).searches, ['Hip hop music']);
      await store.playlists();
      await store.songs();
      expect(lookups, 1);
      final reopened = LibraryStore(directory: () async => dir);
      expect((await reopened.profile()).liked.single.id, 'seed0000001');
    },
  );
  test('failed mutation does not poison later reads or writes', () async {
    final store = LibraryStore(directory: () async => dir);
    await store.createPlaylist('Saved playlist');
    await expectLater(store.createPlaylist(''), throwsArgumentError);
    expect((await store.playlists()).single.name, 'Saved playlist');
    await store.createPlaylist('Another');
    expect((await store.playlists()).length, 2);
  });
  test('corrupt primary library is recovered from the backup', () async {
    final store = LibraryStore(directory: () async => dir);
    await store.setLiked(song('seed0000001'), true);
    await File('${dir.path}/music_library.json').writeAsString('{broken');
    final reopened = LibraryStore(directory: () async => dir);
    expect((await reopened.profile()).liked.single.id, 'seed0000001');
    expect(
      await File('${dir.path}/music_library.json').readAsString(),
      contains('seed0000001'),
    );
  });
}
