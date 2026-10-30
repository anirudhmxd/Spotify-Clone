import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rhythm_app/services/audio_engine.dart';

class _Player extends Fake implements AudioPlayer {
  final sources = <AudioSource>[];
  @override
  Future<Duration?> setAudioSource(
    AudioSource source, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    sources.add(source);
    return const Duration(minutes: 3);
  }
}

void main() {
  test(
    'remote audio includes its end boundary in a single player load',
    () async {
      final player = _Player();
      final engine = JustAudioEngine(player: player);
      await engine.load(
        'https://audio.example/song.m4a',
        end: const Duration(seconds: 181),
      );
      expect(player.sources, hasLength(1));
      final source = player.sources.single as ClippingAudioSource;
      expect(source.end, const Duration(seconds: 181));
      expect(source.child.uri.toString(), 'https://audio.example/song.m4a');
    },
  );
  test('local audio is clipped during its first load', () async {
    final player = _Player();
    final engine = JustAudioEngine(player: player);
    await engine.loadFile(
      '/tmp/saved song.m4a',
      end: const Duration(seconds: 181),
    );
    expect(player.sources, hasLength(1));
    final source = player.sources.single as ClippingAudioSource;
    expect(source.child.uri.toFilePath(), '/tmp/saved song.m4a');
    expect(source.end, const Duration(seconds: 181));
  });
  test(
    'a song with unknown duration does not inherit the prior clip',
    () async {
      final player = _Player();
      final engine = JustAudioEngine(player: player);
      await engine.load(
        'https://audio.example/first',
        end: const Duration(seconds: 181),
      );
      await engine.load('https://audio.example/live');
      expect(player.sources, hasLength(2));
      expect(player.sources.last, isA<UriAudioSource>());
      expect(
        (player.sources.last as UriAudioSource).uri.toString(),
        'https://audio.example/live',
      );
    },
  );
}
