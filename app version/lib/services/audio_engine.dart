import 'dart:io';

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
  Future<void> setEqualizer(String preset);

  Future<void> dispose();
}

class JustAudioEngine implements AudioEngine {
  JustAudioEngine({AudioPlayer? player}) : _suppliedPlayer = player;
  final AudioPlayer? _suppliedPlayer;
  final AndroidEqualizer _equalizer = AndroidEqualizer();

  late final AudioPlayer _player =
      _suppliedPlayer ??
      AudioPlayer(
        useProxyForRequestHeaders: false,
        // Start after a small buffer, while continuing to build a healthy reserve.
        audioLoadConfiguration: const AudioLoadConfiguration(
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
        audioPipeline: AudioPipeline(
          androidAudioEffects: Platform.isAndroid ? [_equalizer] : [],
        ),
      );

  @override
  bool get supportsEqualizer => Platform.isAndroid;

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  @override
  Future<void> setEqualizer(String preset) async {
    if (!supportsEqualizer) return;

    await _equalizer.setEnabled(preset != 'flat');

    if (preset == 'flat') return;

    final params = await _equalizer.parameters.timeout(
      const Duration(seconds: 5),
    );

    for (final band in params.bands) {
      final hz = band.centerFrequency;

      final gain = switch (preset) {
        'bass' =>
          hz < 250
              ? 5.0
              : hz > 2000
              ? -1.0
              : 0.0,
        'vocal' => hz >= 500 && hz <= 4000 ? 3.0 : -1.0,
        'treble' => hz > 4000 ? 4.0 : 0.0,
        _ => 0.0,
      };

      await band.setGain(gain.clamp(params.minDecibels, params.maxDecibels));
    }
  }

  @override
  Stream<Duration> get positions => _player.createPositionStream(
    steps: 1000,
    minPeriod: const Duration(milliseconds: 200),
    maxPeriod: const Duration(milliseconds: 250),
  );

  @override
  Stream<void> get changes => _player.playerStateStream.map((_) {});

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
    // Construct the boundary before loading. setClip after setUrl reloads it.
    await _player.setAudioSource(
      end == null ? source : ClippingAudioSource(child: source, end: end),
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
