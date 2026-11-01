import 'package:flutter/material.dart';
import '../brand.dart';

/// The same visible play, pause and cancel-loading states on every surface.
class PlayButton extends StatelessWidget {
  final bool playing, loading;
  final VoidCallback? onPressed;
  final double size;
  final String? tooltip;
  const PlayButton({
    super.key,
    required this.playing,
    required this.loading,
    required this.onPressed,
    this.size = 44,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) => IconButton.filled(
    tooltip: loading
        ? 'Cancel loading'
        : tooltip ?? (playing ? 'Pause' : 'Play'),
    onPressed: onPressed,
    style: IconButton.styleFrom(
      backgroundColor: RhythmBrand.violet,
      foregroundColor: RhythmBrand.ink,
      disabledBackgroundColor: RhythmBrand.raised,
      disabledForegroundColor: Colors.white38,
      minimumSize: Size.square(size),
    ),
    icon: SizedBox.square(
      dimension: size * .58,
      child: loading
          ? Stack(
              alignment: Alignment.center,
              children: [
                const Positioned.fill(
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: RhythmBrand.ink,
                    semanticsLabel: 'Loading audio',
                  ),
                ),
                Icon(
                  Icons.stop_rounded,
                  size: size * .28,
                  color: RhythmBrand.ink,
                ),
              ],
            )
          : Icon(
              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              size: size * .58,
            ),
    ),
  );
}
