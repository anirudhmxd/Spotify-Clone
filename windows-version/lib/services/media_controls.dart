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
    // duration of fragmented-MP4 audio (sometimes doubled).
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
    // Resolving a user-selected song is an active play request. Keep the
    // foreground service alive during this gap, including background skips.
    final wantsPlayback = !_stopped && (c.audio.playing || c.resolvingAudio);
    final canSeek = c.canSeek && !_stopped;
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          wantsPlayback ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
        systemActions: canSeek
            ? const {
                MediaAction.seek,
                MediaAction.seekForward,
                MediaAction.seekBackward,
              }
            : const {},
        androidCompactActionIndices: const [0, 1, 2],
        processingState: track == null || _stopped
            ? AudioProcessingState.idle
            : c.resolvingAudio
            ? AudioProcessingState.loading
            : c.playbackLoading
            ? AudioProcessingState.buffering
            : AudioProcessingState.ready,
        playing: wantsPlayback,
        updatePosition: c.boundedPosition,
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
    // Repeated system play commands during loading must not toggle it off.
    if (!c.audio.playing && !c.resolvingAudio) await c.togglePlay();
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
  Future<void> seek(Duration position) async {
    if (!c.canSeek || _stopped) return;
    await c.seek(
      Duration(
        milliseconds: position.inMilliseconds.clamp(
          0,
          c.expectedDuration.inMilliseconds,
        ),
      ),
    );
  }

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
