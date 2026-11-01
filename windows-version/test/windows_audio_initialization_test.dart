import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:rhythm/services/audio_engine.dart';

// Exercise the real AudioPlayer initialization, rather than injecting an
// AudioPlayer fake that bypasses platform configuration entirely.
class _WindowsPlatform extends JustAudioPlatform {
  late _WindowsPlayer player;
  InitRequest? request;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    this.request = request;
    // The host Mac's vendored EQ hook is unrelated to Windows initialization.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          MethodChannel('com.ryanheise.just_audio.methods.${request.id}'),
          (_) async => null,
        );
    return player = _WindowsPlayer(request.id);
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(
    DisposePlayerRequest request,
  ) async {
    await player.events.close();
    return DisposePlayerResponse();
  }
}

class _WindowsPlayer extends AudioPlayerPlatform {
  _WindowsPlayer(super.id);
  final events = StreamController<PlaybackEventMessage>.broadcast();
  var loads = 0;

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => events.stream;

  // Deliberately inherit the unsupported Apple-only methods. Calling them
  // throws the same UnimplementedError shown in the Windows screenshot.
  @override
  Future<LoadResponse> load(LoadRequest request) async {
    loads++;
    events.add(
      PlaybackEventMessage(
        processingState: ProcessingStateMessage.ready,
        updateTime: DateTime.now(),
        updatePosition: Duration.zero,
        bufferedPosition: const Duration(minutes: 3),
        duration: const Duration(minutes: 3),
        icyMetadata: null,
        currentIndex: 0,
        androidAudioSessionId: null,
      ),
    );
    return LoadResponse(duration: const Duration(minutes: 3));
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async =>
      SetVolumeResponse();
  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async =>
      SetSpeedResponse();
  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async =>
      SetLoopModeResponse();
  @override
  Future<SetShuffleModeResponse> setShuffleMode(
    SetShuffleModeRequest request,
  ) async => SetShuffleModeResponse();
  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(
    SetShuffleOrderRequest request,
  ) async => SetShuffleOrderResponse();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final local in [false, true]) {
    test(
      'Windows initializes ${local ? 'a file' : 'a stream'} without Apple APIs',
      () async {
        final previous = JustAudioPlatform.instance;
        final platform = _WindowsPlatform();
        JustAudioPlatform.instance = platform;
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        final engine = JustAudioEngine();
        try {
          if (local) {
            await engine.loadFile('/tmp/selected.m4a');
          } else {
            await engine.load('https://audio.example/selected.m4a');
          }
          expect(platform.player.loads, 1);
          expect(engine.loading, isFalse);
          expect(engine.duration, const Duration(minutes: 3));
          expect(
            platform.request!.audioLoadConfiguration?.darwinLoadControl,
            isNull,
          );
        } finally {
          await engine.dispose();
          JustAudioPlatform.instance = previous;
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }
}
