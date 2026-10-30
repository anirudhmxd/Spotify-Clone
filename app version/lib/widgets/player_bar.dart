import '../brand.dart';
import 'play_button.dart';
import 'package:flutter/material.dart';
import '../music_controller.dart';
import 'artwork.dart';
import 'playback_panels.dart';

class PlayerBar extends StatelessWidget {
  final MusicController controller;
  final bool compact;
  const PlayerBar({super.key, required this.controller, required this.compact});
  @override
  Widget build(BuildContext context) {
    final c = controller;
    final track = c.current;
    final metadata = InkWell(
      onTap: () => showNowPlaying(context, c),
      child: Row(
        children: [
          Artwork(url: track?.artwork ?? '', size: compact ? 42 : 52),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  track?.title ?? 'Choose a song',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  c.playbackLoading
                      ? 'Getting your song ready…'
                      : track?.artist ?? 'Your music, ready to play',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: Colors.white60),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    if (compact) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
        child: Material(
          clipBehavior: Clip.antiAlias,
          borderRadius: BorderRadius.circular(18),
          color: RhythmBrand.raised,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                child: Row(
                  children: [
                    Expanded(child: metadata),
                    IconButton(
                      tooltip: 'Queue',
                      onPressed: () => showQueue(context, c),
                      icon: const Icon(Icons.queue_music),
                    ),
                    PlayButton(
                      playing: c.audio.playing,
                      loading: c.playbackLoading,
                      onPressed: track == null ? null : c.togglePlay,
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
              ),
              ValueListenableBuilder<Duration>(
                valueListenable: c.playbackPosition,
                builder: (context, position, _) => LinearProgressIndicator(
                  minHeight: 2,
                  backgroundColor: Colors.white10,
                  value: c.expectedDuration.inMilliseconds <= 0
                      ? 0
                      : (position.inMilliseconds /
                                c.expectedDuration.inMilliseconds)
                            .clamp(0, 1),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return SizedBox(
      height: 108,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(flex: 3, child: metadata),
            IconButton(
              tooltip: 'Like song',
              onPressed: track == null ? null : () => c.toggleLike(track),
              icon: Icon(
                track != null && c.isLiked(track)
                    ? Icons.favorite
                    : Icons.favorite_outline,
                color: RhythmBrand.violet,
              ),
            ),
            Expanded(
              flex: 5,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  PlaybackControls(c: c),
                  SizedBox(height: 30, child: PlaybackTimeline(c: c)),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Queue',
              onPressed: () => showQueue(context, c),
              icon: const Icon(Icons.queue_music),
            ),
            IconButton(
              tooltip: c.volume == 0 ? 'Unmute' : 'Mute',
              onPressed: c.mute,
              icon: Icon(
                c.volume == 0 ? Icons.volume_off : Icons.volume_up,
                size: 20,
              ),
            ),
            SizedBox(
              width: 80,
              child: Slider(value: c.volume, onChanged: c.setVolume),
            ),
          ],
        ),
      ),
    );
  }
}
