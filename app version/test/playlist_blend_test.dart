import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythm_app/brand.dart';
import 'package:rhythm_app/main.dart';
import 'package:rhythm_app/models/music.dart';
import 'package:rhythm_app/music_controller.dart';
import 'package:rhythm_app/services/library_store.dart';
import 'package:rhythm_app/widgets/playlist_blend.dart';
import 'fakes.dart';

class _Repository extends FakeRepository {
  final sources = [
    Playlist(
      id: 'a',
      name: 'Evening favourites',
      tracks: [song('track000001'), song('shared00001')],
    ),
    Playlist(
      id: 'b',
      name: 'Weekend favourites',
      tracks: [song('shared00001'), song('track000002')],
    ),
  ];
  List<String>? selected;
  String? blendName;
  bool fail = false;
  Completer<void>? gate;
  int calls = 0;
  @override
  Future<List<Playlist>> playlists() async => [...sources];
  @override
  Future<Playlist> blendPlaylists(String name, List<String> playlistIds) async {
    calls++;
    selected = playlistIds;
    blendName = name;
    await gate?.future;
    if (fail) throw StateError('Could not save the blend.');
    return Playlist(
      id: 'blend',
      name: name,
      tracks: [song('track000001'), song('shared00001'), song('track000002')],
    );
  }
}

void main() {
  group('saved blends', () {
    late Directory dir;
    late LibraryStore store;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('rhythm-blend-');
      store = LibraryStore(directory: () async => dir);
    });
    tearDown(() async => dir.delete(recursive: true));

    Future<Playlist> source(String name, List<Track> tracks) async {
      final playlist = await store.createPlaylist(name);
      return store.editPlaylist(playlist.copyWith(tracks: tracks));
    }

    test(
      'deduplicates by ID, keeps input order and originals, and survives reopening',
      () async {
        final shared = song('shared00001', 'First metadata wins');
        final a = await source('First', [song('track000001'), shared]);
        final b = await source('Second', [
          song('shared00001', 'Other metadata'),
          song('track000002'),
        ]);
        final blend = await store.blendPlaylists(' Together ', [
          b.id,
          a.id,
          b.id,
        ]);
        expect(blend.name, 'Together');
        expect(blend.tracks.map((t) => t.id), [
          'shared00001',
          'track000002',
          'track000001',
        ]);
        expect(blend.tracks.first.title, 'Other metadata');
        final reopened = LibraryStore(directory: () async => dir);
        expect((await reopened.playlists()).map((p) => p.toJson()), [
          a.toJson(),
          b.toJson(),
          blend.toJson(),
        ]);
      },
    );

    test(
      'invalid selections do not leave a partial playlist or corrupt later writes',
      () async {
        final a = await source('First', []);
        final b = await source('Second', []);
        final original = await File(
          '${dir.path}/music_library.json',
        ).readAsString();
        for (final ids in [
          <String>[],
          [a.id],
          [a.id, a.id],
          [a.id, 'deleted'],
        ]) {
          await expectLater(
            store.blendPlaylists('Invalid', ids),
            throwsA(anyOf(isA<ArgumentError>(), isA<StateError>())),
          );
        }
        await expectLater(
          store.blendPlaylists(' ', [a.id, b.id]),
          throwsArgumentError,
        );
        expect(
          await File('${dir.path}/music_library.json').readAsString(),
          original,
        );
        final empty = await store.blendPlaylists('Empty blend', [a.id, b.id]);
        expect(empty.tracks, isEmpty);
        expect(await store.playlists(), hasLength(3));
      },
    );

    test(
      'blend excludes unverified remote items and retains imported audio',
      () async {
        const video = Track(
          id: 'videotrack1',
          title: 'Older video',
          artist: '',
          album: '',
          artwork: '',
          stream: '',
        );
        final a = await source('First', [video, song('track000001')]);
        final b = await source('Second', [song('local_12345')]);
        final blend = await store.blendPlaylists('Songs only', [a.id, b.id]);
        expect(blend.tracks.map((t) => t.id), ['track000001', 'local_12345']);
        expect((await store.playlists()).first.tracks.first.id, video.id);
      },
    );

    test('more than 5,000 unique songs is rejected before saving', () async {
      final a = await source(
        'Large',
        List.generate(
          5001,
          (i) => song('track${i.toString().padLeft(6, '0')}'),
        ),
      );
      final b = await source('Empty', []);
      final before = await File(
        '${dir.path}/music_library.json',
      ).readAsString();
      await expectLater(
        store.blendPlaylists('Too large', [a.id, b.id]),
        throwsArgumentError,
      );
      expect(await store.playlists(), hasLength(2));
      expect(
        await File('${dir.path}/music_library.json').readAsString(),
        before,
      );
    });
  });

  for (final width in [360.0, 1280.0]) {
    testWidgets(
      'blend picker works at width $width and follows displayed source order',
      (tester) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final repo = _Repository();
        final c = MusicController(repo, FakeAudio())
          ..playlists = [...repo.sources];
        addTearDown(c.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: RhythmBrand.theme,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showPlaylistBlend(context, c),
                  child: const Text('Open blend'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open blend'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilledButton>(find.byKey(const ValueKey('create-blend')))
              .onPressed,
          isNull,
        );
        // Reverse tap order must not reverse the order shown to the user.
        await tester.tap(find.byKey(const ValueKey('blend-source-b')));
        await tester.tap(find.byKey(const ValueKey('blend-source-a')));
        await tester.pump();
        expect(
          find.text('2 playlists selected · 3 unique songs'),
          findsOneWidget,
        );
        await tester.enterText(find.byKey(const ValueKey('blend-name')), ' ');
        await tester.pump();
        expect(
          tester
              .widget<FilledButton>(find.byKey(const ValueKey('create-blend')))
              .onPressed,
          isNull,
        );
        await tester.enterText(
          find.byKey(const ValueKey('blend-name')),
          'Our Blend',
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('create-blend')));
        await tester.pumpAndSettle();
        expect(repo.selected, ['a', 'b']);
        expect(repo.blendName, 'Our Blend');
        expect(c.activePlaylistId, 'blend');
        expect(c.playlists.map((p) => p.id), ['a', 'b', 'blend']);
        expect(c.mutating, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'playlist page preselects its source; failed save stays open and can be retried',
    (tester) async {
      final repo = _Repository()..fail = true;
      final c = MusicController(repo, FakeAudio());
      await tester.pumpWidget(MusicApp(controller: c));
      await tester.pumpAndSettle();
      c.openPlaylist(c.playlists.first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Blend playlists'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('blend-source-a')),
            )
            .value,
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('blend-source-b')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('create-blend')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('create-blend')), findsOneWidget);
      expect(c.playlists, hasLength(2));
      repo.fail = false;
      await tester.tap(find.byKey(const ValueKey('create-blend')));
      await tester.pumpAndSettle();
      expect(c.activePlaylistId, 'blend');
      expect(c.playlists, hasLength(3));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets('library entry opens the picker; cancelling creates nothing', (
    tester,
  ) async {
    final repo = _Repository();
    final c = MusicController(repo, FakeAudio());
    await tester.pumpWidget(MusicApp(controller: c));
    await tester.pumpAndSettle();
    c.navigate(MusicPage.library);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Blend playlists').last);
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(repo.calls, 0);
    expect(c.playlists, hasLength(2));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
