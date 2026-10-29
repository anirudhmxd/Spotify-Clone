import 'package:flutter/material.dart';

import '../models/music.dart';
import '../music_controller.dart';
import 'artwork.dart';

class PlayerBar extends StatelessWidget {
  final MusicController controller;
  final bool compact;
  const PlayerBar({super.key, required this.controller, required this.compact});
  @override
  Widget build(BuildContext context) {
    final c = controller;
    final track = c.current;
    final duration = c.audio.duration;
    final max = duration.inMilliseconds.toDouble();
    final position = c.audio.position.inMilliseconds.toDouble().clamp(
      0.0,
      max > 0 ? max : 1.0,
    );
    final controls = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Previous',
          onPressed: c.queue.isEmpty ? null : c.previous,
          icon: const Icon(Icons.skip_previous),
        ),
        IconButton.filled(
          tooltip: c.audio.playing ? 'Pause' : 'Play',
          onPressed: track == null ? null : c.togglePlay,
          icon: (c.audio.loading || c.resolvingAudio)
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(c.audio.playing ? Icons.pause : Icons.play_arrow),
        ),
        IconButton(
          tooltip: 'Next',
          onPressed: c.queue.isEmpty ? null : () => c.next(),
          icon: const Icon(Icons.skip_next),
        ),
        IconButton(
          tooltip: c.loop ? 'Repeat on' : 'Repeat off',
          onPressed: c.toggleLoop,
          icon: Icon(
            Icons.repeat,
            color: c.loop ? const Color(0xff1ed760) : Colors.white60,
          ),
        ),
      ],
    );
    final timeline = Row(
      children: [
        Text(
          formatTime(c.audio.position),
          style: const TextStyle(fontSize: 10, color: Colors.white60),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            ),
            child: Slider(
              label: 'Playback position',
              value: position,
              max: max > 0 ? max : 1,
              onChanged: max <= 0
                  ? null
                  : (value) => c.seek(Duration(milliseconds: value.round())),
            ),
          ),
        ),
        Text(
          formatTime(duration),
          style: const TextStyle(fontSize: 10, color: Colors.white60),
        ),
      ],
    );
    final metadata = Row(
      children: [
        Artwork(url: track?.artwork ?? '', size: compact ? 40 : 52),
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
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                track?.artist ?? 'Your music, ready to play',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Colors.white60),
              ),
            ],
          ),
        ),
      ],
    );
    final volume = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: c.volume == 0 ? 'Unmute' : 'Mute',
          onPressed: c.mute,
          icon: Icon(
            c.volume == 0 ? Icons.volume_off : Icons.volume_up,
            size: 20,
          ),
        ),
        SizedBox(
          width: compact ? 110 : 100,
          child: Slider(
            label: 'Volume',
            value: c.volume,
            onChanged: c.setVolume,
          ),
        ),
      ],
    );
    if (compact) {
      return Container(
        color: const Color(0xff181818),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            metadata,
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                controls,
                IconButton(
                  tooltip: 'Volume',
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    showDragHandle: true,
                    builder: (_) => SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: ListenableBuilder(
                          listenable: c,
                          builder: (_, child) => Row(
                            children: [
                              IconButton(
                                tooltip: 'Mute or unmute',
                                onPressed: c.mute,
                                icon: Icon(
                                  c.volume == 0
                                      ? Icons.volume_off
                                      : Icons.volume_up,
                                ),
                              ),
                              Expanded(
                                child: Slider(
                                  label: 'Volume',
                                  value: c.volume,
                                  onChanged: c.setVolume,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.volume_up_outlined),
                ),
              ],
            ),
            timeline,
          ],
        ),
      );
    }
    return Container(
      height: 102,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(child: metadata),
          const SizedBox(width: 24),
          Expanded(
            flex: 2,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                controls,
                SizedBox(height: 30, child: timeline),
              ],
            ),
          ),
          const SizedBox(width: 24),
          Expanded(
            child: Align(alignment: Alignment.centerRight, child: volume),
          ),
        ],
      ),
    );
  }
}
