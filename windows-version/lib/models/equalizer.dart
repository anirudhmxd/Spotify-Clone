abstract final class Equalizer {
  static const frequencies = [60.0, 230.0, 910.0, 3600.0, 14000.0];
  static const labels = ['60 Hz', '230 Hz', '910 Hz', '3.6 kHz', '14 kHz'];
  static const presets = <String, List<double>>{
    'flat': [0, 0, 0, 0, 0],
    'bass': [6, 4, 0, -1, -1],
    'vocal': [-2, 0, 4, 3, -1],
    'treble': [-1, -1, 0, 4, 6],
  };
  static List<double> sanitize(dynamic value, {String preset = 'flat'}) {
    final fallback = presets[preset] ?? presets['flat']!;
    return List.unmodifiable(
      List.generate(5, (i) {
        final v = value is List && i < value.length ? value[i] : fallback[i];
        return v is num && v.toDouble().isFinite
            ? v.toDouble().clamp(-12.0, 12.0)
            : 0.0;
      }),
    );
  }
}
