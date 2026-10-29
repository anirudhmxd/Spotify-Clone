import '../brand.dart';
import 'dart:math';
import 'package:flutter/material.dart' hide RepeatMode;
import '../models/experience.dart';
import '../models/music.dart';
import '../music_controller.dart';
import 'artwork.dart';
import 'experience_pages.dart';

class PlaybackControls extends StatelessWidget {
  final MusicController c;
  final bool large;
  const PlaybackControls({super.key, required this.c, this.large = false});
  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        tooltip: c.shuffle ? 'Shuffle on' : 'Shuffle off',
        onPressed: c.toggleShuffle,
        icon: Icon(
          Icons.shuffle,
          color: c.shuffle ? RhythmBrand.violet : Colors.white60,
        ),
      ),
      IconButton(
        tooltip: 'Previous',
        onPressed: c.queue.isEmpty ? null : c.previous,
        icon: const Icon(Icons.skip_previous),
      ),
      IconButton.filled(
        iconSize: large ? 38 : 24,
        tooltip: c.audio.playing ? 'Pause' : 'Play',
        onPressed: c.current == null ? null : c.togglePlay,
        icon: c.audio.loading || c.resolvingAudio
            ? const SizedBox(
                width: 24,
                height: 24,
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
        tooltip: 'Repeat: ${c.repeatMode.name}',
        onPressed: c.toggleLoop,
        icon: Icon(
          c.repeatMode == RepeatMode.one ? Icons.repeat_one : Icons.repeat,
          color: c.repeatMode == RepeatMode.off
              ? Colors.white60
              : RhythmBrand.violet,
        ),
      ),
    ],
  );
}

class PlaybackTimeline extends StatelessWidget {
  final MusicController c;
  const PlaybackTimeline({super.key, required this.c});
  @override
  Widget build(BuildContext context) {
    final maximum = max(1, c.audio.duration.inMilliseconds).toDouble();
    return Row(
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
            ),
            child: Slider(
              semanticFormatterCallback: (v) =>
                  formatTime(Duration(milliseconds: v.round())),
              value: c.audio.position.inMilliseconds.toDouble().clamp(
                0,
                maximum,
              ),
              max: maximum,
              onChanged: c.audio.duration == Duration.zero
                  ? null
                  : (v) => c.seek(Duration(milliseconds: v.round())),
            ),
          ),
        ),
        Text(
          formatTime(c.audio.duration),
          style: const TextStyle(fontSize: 10, color: Colors.white60),
        ),
      ],
    );
  }
}

Future<void> showQueue(BuildContext context, MusicController c) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .75,
          child: ListenableBuilder(
            listenable: c,
            builder: (context, _) => Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Play queue',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: c.queue.isEmpty ? null : c.clearUpcoming,
                        child: const Text('Clear upcoming'),
                      ),
                    ],
                  ),
                ),
                if (c.queue.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'Add a song using its menu to build your queue.',
                    ),
                  ),
                Expanded(
                  child: ReorderableListView.builder(
                    itemCount: c.queue.length,
                    onReorderItem: c.reorderQueue,
                    itemBuilder: (_, index) {
                      final track = c.queue[index];
                      return ListTile(
                        key: ValueKey('$index-${track.id}'),
                        leading: Artwork(url: track.artwork, size: 40),
                        title: Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: index == c.queueIndex
                                ? RhythmBrand.violet
                                : null,
                          ),
                        ),
                        subtitle: Text(
                          index == c.queueIndex ? 'Now playing' : track.artist,
                          maxLines: 1,
                        ),
                        onTap: () => c.playQueueIndex(index),
                        trailing: Padding(
                          padding: const EdgeInsets.only(right: 28),
                          child: IconButton(
                            tooltip: 'Remove from queue',
                            onPressed: index == c.queueIndex
                                ? null
                                : () => c.removeQueueItem(index),
                            icon: const Icon(Icons.close),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
Future<void> showNowPlaying(
  BuildContext context,
  MusicController c,
) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    builder: (_) => ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final track = c.current;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Now playing'),
            actions: [
              IconButton(
                tooltip: 'Sleep timer',
                onPressed: () => showSleepTimer(context, c),
                icon: const Icon(Icons.bedtime_outlined),
              ),
            ],
          ),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 540),
                child: ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    const SizedBox(height: 16),
                    Center(
                      child: Artwork(
                        url: track?.artwork ?? '',
                        size: min(360, MediaQuery.sizeOf(context).width - 48),
                      ),
                    ),
                    const SizedBox(height: 32),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                track?.title ?? 'Choose a song',
                                style: const TextStyle(
                                  fontSize: 26,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              TextButton(
                                onPressed: track == null
                                    ? null
                                    : () {
                                        c.openArtist(track.artist);
                                        Navigator.pop(context);
                                      },
                                child: Text(track?.artist ?? ''),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: track != null && c.isLiked(track)
                              ? 'Unlike'
                              : 'Like',
                          onPressed: track == null
                              ? null
                              : () => c.toggleLike(track),
                          icon: Icon(
                            track != null && c.isLiked(track)
                                ? Icons.favorite
                                : Icons.favorite_border,
                            color: RhythmBrand.violet,
                          ),
                        ),
                      ],
                    ),
                    PlaybackTimeline(c: c),
                    PlaybackControls(c: c, large: true),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        IconButton(
                          tooltip: 'Mute',
                          onPressed: c.mute,
                          icon: Icon(
                            c.volume == 0 ? Icons.volume_off : Icons.volume_up,
                          ),
                        ),
                        Expanded(
                          child: Slider(
                            value: c.volume,
                            onChanged: c.setVolume,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Queue',
                          onPressed: () => showQueue(context, c),
                          icon: const Icon(Icons.queue_music),
                        ),
                      ],
                    ),
                    if (c.sleepUntil != null || c.sleepAfterTrack)
                      TextButton.icon(
                        onPressed: () => showSleepTimer(context, c),
                        icon: const Icon(Icons.bedtime),
                        label: const Text('Sleep timer is on'),
                      ),
                    if (track != null)
                      Text(
                        c.isDownloaded(track)
                            ? 'Playing from your device when available'
                            : 'Streaming audio',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white60),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    ),
  ),
);
