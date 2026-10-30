import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import '../brand.dart';
import '../models/equalizer.dart';
import '../music_controller.dart';

class EqualizerPanel extends StatefulWidget {
  final MusicController controller;
  const EqualizerPanel({super.key, required this.controller});
  @override
  State<EqualizerPanel> createState() => _EqualizerPanelState();
}

class _EqualizerPanelState extends State<EqualizerPanel>
    with WidgetsBindingObserver {
  final _waveform = ValueNotifier<List<double>>(const []);
  Timer? _timer;
  int _band = 0;
  bool _reading = false, _visualizing = false, _foreground = true;
  MusicController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(
      const Duration(milliseconds: 50),
      (_) => _readWaveform(),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) _readWaveform();
  }

  Future<void> _readWaveform() async {
    if (_reading || !mounted) return;
    _reading = true;
    try {
      final active =
          _foreground &&
          c.audio.playing &&
          !c.playbackLoading &&
          c.audio.supportsEqualizer;
      if (!active) {
        if (_visualizing) await c.audio.waveform(enabled: false);
        _visualizing = false;
        if (mounted && _waveform.value.isNotEmpty) _waveform.value = const [];
      } else {
        _visualizing = true;
        final samples = await c.audio.waveform();
        if (mounted) _waveform.value = samples;
      }
    } catch (_) {
      if (mounted) _waveform.value = const [];
    } finally {
      _reading = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(
      c.audio.waveform(enabled: false).catchError((Object _) => <double>[]),
    );
    _waveform.dispose();
    super.dispose();
  }

  void _adjust(Offset position, Size size) {
    if (!c.audio.supportsEqualizer || !c.settings.equalizerEnabled) return;
    final plot = _EqualizerPainter.plot(size);
    final index = ((position.dx - plot.left) / plot.width * 4).round().clamp(
      0,
      4,
    );
    final gain = (1 - 2 * (position.dy - plot.top) / plot.height) * 12;
    setState(() => _band = index);
    c.setEqualizerBand(index, gain);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) {
      final gains = c.settings.eqGains;
      final active = c.settings.equalizerEnabled && c.audio.supportsEqualizer;
      final headroom = gains.fold<double>(0, max);
      return Card(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Equalizer',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Switch(
                    value: c.settings.equalizerEnabled,
                    onChanged: c.audio.supportsEqualizer
                        ? c.enableEqualizer
                        : null,
                  ),
                ],
              ),
              const Text(
                'Shape your sound',
                style: TextStyle(color: Colors.white60),
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final entry in const {
                    'flat': 'Flat',
                    'bass': 'Bass',
                    'vocal': 'Vocals',
                    'treble': 'Treble',
                  }.entries)
                    ChoiceChip(
                      label: Text(entry.value),
                      selected: c.settings.equalizer == entry.key,
                      onSelected: active
                          ? (_) => c.setEqualizerPreset(entry.key)
                          : null,
                    ),
                ],
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) {
                  final size = Size(constraints.maxWidth, 240);
                  return RepaintBoundary(
                    child: Semantics(
                      label:
                          'Equalizer gain curve. Drag a point to change a band. Use the gain slider for precise adjustment.',
                      child: GestureDetector(
                        key: const ValueKey('equalizer-graph'),
                        onPanDown: active
                            ? (d) => _adjust(d.localPosition, size)
                            : null,
                        onPanUpdate: active
                            ? (d) => _adjust(d.localPosition, size)
                            : null,
                        child: CustomPaint(
                          size: size,
                          painter: _EqualizerPainter(
                            axisStyle: Theme.of(context).textTheme.labelSmall!
                                .copyWith(fontSize: 10, color: Colors.white54),
                            gains: gains,
                            enabled: active,
                            band: _band,
                            waveform: _waveform,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                spacing: 12,
                runSpacing: 6,
                children: [
                  Text(
                    'Live waveform',
                    style: TextStyle(
                      fontSize: 11,
                      color: c.audio.playing && !c.playbackLoading
                          ? RhythmBrand.cyan
                          : Colors.white38,
                    ),
                  ),
                  Text(
                    active && headroom > 0
                        ? 'Headroom −${headroom.toStringAsFixed(1)} dB'
                        : active
                        ? 'Flat level'
                        : 'EQ off',
                    style: const TextStyle(fontSize: 11, color: Colors.white54),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (var i = 0; i < 5; i++)
                    ChoiceChip(
                      label: Text(Equalizer.labels[i]),
                      selected: _band == i,
                      onSelected: active
                          ? (_) => setState(() => _band = i)
                          : null,
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: Text('${Equalizer.labels[_band]} gain')),
                  Text(
                    '${gains[_band] > 0 ? '+' : ''}${gains[_band].toStringAsFixed(1)} dB',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              Slider(
                key: const ValueKey('equalizer-gain'),
                label:
                    '${Equalizer.labels[_band]} ${gains[_band].toStringAsFixed(1)} decibels',
                min: -12,
                max: 12,
                divisions: 48,
                value: gains[_band],
                onChanged: active
                    ? (gain) => c.setEqualizerBand(_band, gain)
                    : null,
              ),
              if (c.current == null)
                const Text(
                  'Play a song to hear changes and see its waveform.',
                  style: TextStyle(color: Colors.white60),
                ),
              if (!c.audio.supportsEqualizer)
                const Text('Equalizer is unavailable on this device.'),
              if (c.equalizerError != null)
                Text(
                  c.equalizerError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      );
    },
  );
}

class _EqualizerPainter extends CustomPainter {
  final TextStyle axisStyle;
  final List<double> gains;
  final bool enabled;
  final int band;
  final ValueNotifier<List<double>> waveform;
  _EqualizerPainter({
    required this.axisStyle,
    required this.gains,
    required this.enabled,
    required this.band,
    required this.waveform,
  }) : super(repaint: waveform);
  static Rect plot(Size size) =>
      Rect.fromLTRB(30, 20, size.width - 14, size.height - 30);
  @override
  void paint(Canvas canvas, Size size) {
    final area = plot(size);
    final grid = Paint()
      ..color = Colors.white.withValues(alpha: .08)
      ..strokeWidth = 1;
    void text(String value, Offset position) {
      final painter = TextPainter(
        text: TextSpan(text: value, style: axisStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(canvas, position);
    }

    for (final db in [-12, -6, 0, 6, 12]) {
      final y = area.center.dy - db / 24 * area.height;
      canvas.drawLine(Offset(area.left, y), Offset(area.right, y), grid);
      text(db > 0 ? '+$db' : '$db', Offset(0, y - 6));
    }
    final samples = waveform.value;
    if (samples.length > 1) {
      final wave = Path();
      for (var i = 0; i < samples.length; i++) {
        final x = area.left + i / (samples.length - 1) * area.width;
        final y = area.center.dy - samples[i].clamp(-1, 1) * area.height * .45;
        if (i == 0) {
          wave.moveTo(x, y);
        } else {
          wave.lineTo(x, y);
        }
      }
      canvas.drawPath(
        wave,
        Paint()
          ..color = RhythmBrand.cyan.withValues(alpha: .35)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    final points = List.generate(
      5,
      (i) => Offset(
        area.left + i / 4 * area.width,
        area.center.dy - (enabled ? gains[i] : 0) / 24 * area.height,
      ),
    );
    final curve = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length; i++) {
      final middle = (points[i - 1].dx + points[i].dx) / 2;
      curve.cubicTo(
        middle,
        points[i - 1].dy,
        middle,
        points[i].dy,
        points[i].dx,
        points[i].dy,
      );
    }
    final fill = Path.from(curve)
      ..lineTo(area.right, area.bottom)
      ..lineTo(area.left, area.bottom)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            RhythmBrand.violet.withValues(alpha: .2),
            RhythmBrand.violet.withValues(alpha: 0),
          ],
        ).createShader(area),
    );
    canvas.drawPath(
      curve,
      Paint()
        ..color = enabled ? RhythmBrand.violet : Colors.white38
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    for (var i = 0; i < 5; i++) {
      canvas.drawCircle(
        points[i],
        i == band ? 8 : 5,
        Paint()..color = enabled ? RhythmBrand.violet : Colors.white38,
      );
      if (i == band) {
        canvas.drawCircle(points[i], 3, Paint()..color = RhythmBrand.ink);
      }
      final label = ['60', '230', '910', '3.6k', '14k'][i];
      text(label, Offset(points[i].dx - 8, area.bottom + 10));
    }
  }

  @override
  bool shouldRepaint(covariant _EqualizerPainter old) =>
      old.gains != gains || old.enabled != enabled || old.band != band;
}
