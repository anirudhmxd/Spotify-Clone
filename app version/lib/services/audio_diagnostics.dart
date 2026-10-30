import 'package:flutter/foundation.dart';

/// Console-only diagnostics; never log signed URLs, headers or cookies.
class AudioDiagnostics {
  static const enabled = bool.fromEnvironment(
    'AUDIO_DIAGNOSTICS',
    defaultValue: !kReleaseMode,
  );
  static final _clock = Stopwatch()..start();
  static String redact(Object value) => value
      .toString()
      .replaceAll(RegExp(r'https?://[^\s<>"\x27]+'), '<url>')
      .replaceAll(RegExp(r'[\r\n]+'), ' ');
  static void log(String stage, Object detail) {
    if (!enabled) return;
    final safe = redact(detail);
    debugPrint(
      '[AUDIO +${_clock.elapsedMilliseconds}ms] $stage ${safe.length > 1000 ? safe.substring(0, 1000) : safe}',
    );
  }
}
