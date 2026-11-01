import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

abstract class AudioEngine {
  Stream<Duration> get positions;
  Stream<void> get changes;
  Stream<void> get completions;

  Duration get position;
  Duration get duration;

  bool get playing;
  bool get loading;

  Future<void> load(String url, {Duration? end});
  Future<void> loadFile(String path, {Duration? end});
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);
  Future<void> setLoop(bool loop);
  Future<void> setSpeed(double speed);

  bool get supportsEqualizer;
  Future<void> setEqualizer(List<double> gains, {bool enabled = true});
  Future<List<double>> waveform({bool enabled = true});

  Future<void> dispose();
}

class JustAudioEngine implements AudioEngine {
  JustAudioEngine({AudioPlayer? player}) : _suppliedPlayer = player;
  final AudioPlayer? _suppliedPlayer;

  late final AudioPlayer _player =
      _suppliedPlayer ??
      AudioPlayer(
        useProxyForRequestHeaders: false,
        // Start after a small buffer, while continuing to build a healthy reserve.
        audioLoadConfiguration: const AudioLoadConfiguration(
          darwinLoadControl: DarwinLoadControl(
            automaticallyWaitsToMinimizeStalling: false,
            preferredForwardBufferDuration: Duration(seconds: 3),
          ),
          androidLoadControl: AndroidLoadControl(
            minBufferDuration: Duration(seconds: 15),
            maxBufferDuration: Duration(seconds: 45),
            bufferForPlaybackDuration: Duration(milliseconds: 350),
            bufferForPlaybackAfterRebufferDuration: Duration(
              milliseconds: 1500,
            ),
            prioritizeTimeOverSizeThresholds: true,
          ),
        ),
      );

  @override
  bool get supportsEqualizer =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  @override
  Future<void> setEqualizer(List<double> gains, {bool enabled = true}) =>
      _player.setRhythmEqualizer(gains, enabled: enabled);

  @override
  Future<List<double>> waveform({bool enabled = true}) async {
    final data = await _player.rhythmWaveform(enabled: enabled);
    return (data['samples'] as List? ?? [])
        .whereType<num>()
        .map((n) => n.toDouble())
        .toList();
  }

  @override
  Stream<Duration> get positions => _player.createPositionStream(
    steps: 1000,
    minPeriod: const Duration(milliseconds: 200),
    maxPeriod: const Duration(milliseconds: 250),
  );

  @override
  Stream<void> get changes => Stream<void>.multi((events) {
    final states = _player.playerStateStream.listen(
      (_) => events.add(null),
      onError: events.addError,
    );
    // Runtime failures are published separately from player state changes.
    final errors = _player.errorStream.listen(events.addError);
    events.onCancel = () {
      unawaited(states.cancel());
      unawaited(errors.cancel());
    };
  });

  @override
  Stream<void> get completions => _player.processingStateStream
      .where((state) => state == ProcessingState.completed)
      .map((_) {});

  @override
  Duration get position => _player.position;

  @override
  Duration get duration => _player.duration ?? Duration.zero;

  @override
  bool get playing => _player.playing;

  @override
  bool get loading =>
      _player.processingState == ProcessingState.loading ||
      _player.processingState == ProcessingState.buffering;

  @override
  Future<void> load(String url, {Duration? end}) => _load(Uri.parse(url), end);

  @override
  Future<void> loadFile(String path, {Duration? end}) =>
      _load(Uri.file(path), end);

  Future<void> _load(Uri uri, Duration? end) async {
    final source = AudioSource.uri(uri);
    // just_audio_windows does not reliably support clipping. The controller's
    // position safeguard enforces the catalog end on Windows instead.
    final clip = end != null && defaultTargetPlatform != TargetPlatform.windows;
    // Construct supported boundaries before loading; setClip would reload.
    await _player.setAudioSource(
      clip ? ClippingAudioSource(child: source, end: end) : source,
    );
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);

  @override
  Future<void> setLoop(bool loop) =>
      _player.setLoopMode(loop ? LoopMode.one : LoopMode.off);

  @override
  Future<void> dispose() => _player.dispose();
}
