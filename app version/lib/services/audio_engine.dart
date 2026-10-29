import 'package:just_audio/just_audio.dart';

abstract class AudioEngine {
  Stream<Duration> get positions;
  Stream<void> get changes;
  Stream<void> get completions;
  Duration get position;
  Duration get duration;
  bool get playing;
  bool get loading;
  Future<void> load(String url);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);
  Future<void> setLoop(bool loop);
  Future<void> dispose();
}

class JustAudioEngine implements AudioEngine {
  final AudioPlayer _player = AudioPlayer(useProxyForRequestHeaders: false);
  @override
  Stream<Duration> get positions => _player.positionStream;
  @override
  Stream<void> get changes => _player.playerStateStream.map((_) {});
  @override
  Stream<void> get completions => _player.processingStateStream
      .where((s) => s == ProcessingState.completed)
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
  Future<void> load(String url) async {
    await _player.setUrl(url);
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
