import 'package:audio_service/audio_service.dart';
import '../models/experience.dart' as app;
import '../models/music.dart';
import '../music_controller.dart';

/// Native lock-screen, notification, headset and Bluetooth controls.
class DeviceMediaHandler extends BaseAudioHandler with SeekHandler {
  final MusicController c;
  String _lastQueue = '', _lastItem = '';
  bool _stopped = false;
  DeviceMediaHandler(this.c) {
    c.addListener(_publish);
    _publish();
  }
  MediaItem _item(Track track) => MediaItem(
    id: track.id,
    title: track.title,
    artist: track.artist,
    album: track.album,
    artUri: Uri.tryParse(track.artwork)?.hasAbsolutePath == true
        ? Uri.tryParse(track.artwork)
        : null,
    // Use expectedDuration (authoritative YouTube metadata) instead of
    // c.audio.duration, because AVFoundation on macOS misreports the
    // duration of yt-dlp's fragmented-MP4 downloads (often doubled).
    duration: c.current?.id == track.id
        ? c.expectedDuration
        : Duration(milliseconds: track.durationMs),
  );
  void _publish() {
    final signature = c.queue.map((t) => t.id).join('|');
    if (_lastQueue != signature) {
      _lastQueue = signature;
      queue.add(c.queue.map(_item).toList());
    }
    final track = c.current;
    final itemKey = '${track?.id}/${c.expectedDuration}';
    if (_lastItem != itemKey) {
      _lastItem = itemKey;
      mediaItem.add(track == null ? null : _item(track));
    }
    if (c.audio.playing || c.resolvingAudio) _stopped = false;
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          c.audio.playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: track == null || _stopped
            ? AudioProcessingState.idle
            : c.resolvingAudio
            ? AudioProcessingState.loading
            : c.audio.loading
            ? AudioProcessingState.buffering
            : AudioProcessingState.ready,
        playing: c.audio.playing,
        updatePosition: c.audio.position,
        speed: c.settings.speed,
        queueIndex: c.queueIndex < 0 ? null : c.queueIndex,
        repeatMode: switch (c.repeatMode) {
          app.RepeatMode.off => AudioServiceRepeatMode.none,
          app.RepeatMode.all => AudioServiceRepeatMode.all,
          app.RepeatMode.one => AudioServiceRepeatMode.one,
        },
        shuffleMode: c.shuffle
            ? AudioServiceShuffleMode.all
            : AudioServiceShuffleMode.none,
      ),
    );
  }

  @override
  Future<void> play() async {
    if (!c.audio.playing) await c.togglePlay();
  }

  @override
  Future<void> pause() => c.pause();
  @override
  Future<void> stop() async {
    await c.pause();
    _stopped = true;
    _publish();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) => c.seek(position);
  @override
  Future<void> skipToNext() => c.next();
  @override
  Future<void> skipToPrevious() => c.previous();
  @override
  Future<void> skipToQueueItem(int index) => c.playQueueIndex(index);
  @override
  Future<void> setSpeed(double speed) =>
      c.updateSettings(c.settings.copyWith(speed: speed.clamp(.5, 2)));
  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) =>
      c.setRepeat(switch (repeatMode) {
        AudioServiceRepeatMode.one => app.RepeatMode.one,
        AudioServiceRepeatMode.all ||
        AudioServiceRepeatMode.group => app.RepeatMode.all,
        _ => app.RepeatMode.off,
      });
  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    if ((shuffleMode != AudioServiceShuffleMode.none) != c.shuffle) {
      c.toggleShuffle();
    }
  }
}
