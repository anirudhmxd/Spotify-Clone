import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhythm_app/music_controller.dart';
import 'package:rhythm_app/models/experience.dart';
import 'fakes.dart';

void main() {
  late FakeRepository repo;
  late MusicController controller;
  setUp(() {
    repo = FakeRepository();
    controller = MusicController(repo, FakeAudio());
  });
  tearDown(() => controller.dispose());
  test(
    'batch downloads two at a time and refreshes the library once',
    () async {
      final gates = List.generate(3, (_) => Completer<String>());
      repo.onDownload = (track) => gates[int.parse(track.id)].future;
      final batch = controller.downloadTracks([
        song('0'),
        song('1'),
        song('2'),
      ]);
      expect(controller.downloadingBatch, isTrue);
      expect(repo.downloaded, ['0', '1']);
      await controller.downloadTracks([song('3')]);
      expect(repo.downloaded, ['0', '1']);
      gates[0].complete('/tmp/0.m4a');
      await Future<void>.delayed(Duration.zero);
      expect(repo.downloaded, ['0', '1', '2']);
      expect(repo.profileReads, 0);
      gates[1].complete('/tmp/1.m4a');
      gates[2].complete('/tmp/2.m4a');
      await batch;
      expect(repo.profileReads, 1);
      expect(controller.profile.downloads.length, 3);
      expect(controller.downloading, isEmpty);
      expect(controller.downloadingBatch, isFalse);
    },
  );
  test(
    'batch skips duplicates, saved songs and local files; survives failure',
    () async {
      final saved = DownloadRecord(
        track: song('saved'),
        path: '/tmp/saved',
        bytes: 10,
      );
      repo.data = LibraryProfile(downloads: [saved]);
      controller.profile = repo.data;
      repo.onDownload = (track) async {
        if (track.id == 'fail') throw StateError('Connection lost');
        return '/tmp/${track.id}';
      };
      await controller.downloadTracks([
        song('fail'),
        song('ok'),
        song('ok'),
        song('saved'),
        song('local_1'),
        song('last'),
      ]);
      expect(repo.downloaded, ['fail', 'ok', 'last']);
      expect(controller.profile.downloads.map((d) => d.track.id), [
        'saved',
        'ok',
        'last',
      ]);
      expect(controller.downloadingBatch, isFalse);
      expect(controller.downloading, isEmpty);
    },
  );
}
