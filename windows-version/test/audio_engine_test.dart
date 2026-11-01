import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rhythm/services/audio_engine.dart';

class _Player extends Fake implements AudioPlayer {
  final sources = <AudioSource>[];
  final states = StreamController<PlayerState>.broadcast(sync: true);
  final errors = StreamController<PlayerException>.broadcast(sync: true);
  @override
  Stream<PlayerState> get playerStateStream => states.stream;
  @override
  Stream<PlayerException> get errorStream => errors.stream;
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
    'changes forwards runtime errors and cancels both subscriptions',
    () async {
      final player = _Player();
      final engine = JustAudioEngine(player: player);
      final errors = <Object>[];
      var changes = 0;
      final subscription = engine.changes.listen(
        (_) => changes++,
        onError: errors.add,
      );
      // Stream.multi delivers events asynchronously.
      player.states.add(PlayerState(true, ProcessingState.ready));
      final error = PlayerException(1, 'Network connection lost', null);
      player.errors.add(error);
      await Future<void>.delayed(Duration.zero);
      expect(changes, 1);
      expect(errors, [error]);
      await subscription.cancel();
      expect(player.states.hasListener, isFalse);
      expect(player.errors.hasListener, isFalse);
      await player.states.close();
      await player.errors.close();
    },
  );
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
  test('Windows streams bypass unsupported native clipping', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final player = _Player();
    final engine = JustAudioEngine(player: player);
    await engine.load(
      'https://audio.example/selected.m4a',
      end: const Duration(seconds: 181),
    );
    expect(player.sources, hasLength(1));
    expect(player.sources.single, isA<UriAudioSource>());
    expect(
      (player.sources.single as UriAudioSource).uri.toString(),
      'https://audio.example/selected.m4a',
    );
  });

  test('Windows saved files bypass unsupported native clipping', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final player = _Player();
    final engine = JustAudioEngine(player: player);
    await engine.loadFile(
      '/tmp/selected song.m4a',
      end: const Duration(seconds: 181),
    );
    expect(player.sources, hasLength(1));
    expect(player.sources.single, isA<UriAudioSource>());
    expect(
      (player.sources.single as UriAudioSource).uri.toFilePath(),
      '/tmp/selected song.m4a',
    );
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
