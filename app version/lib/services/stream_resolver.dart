import 'dart:async';
import 'audio_diagnostics.dart';

/// Races metadata-only extractors; never downloads a complete media file.
/// One stalled provider cannot hold up an already available stream.
class StreamResolver {
  StreamResolver({
    required this.direct,
    this.native,
    this.cancelNative,
    this.directTimeout = const Duration(seconds: 5),
    this.nativeTimeout = const Duration(seconds: 12),
    this.nativeDelay = const Duration(milliseconds: 800),
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  final Future<String?> Function(String) direct;
  final Future<String?> Function(String)? native;
  final Future<void> Function(String)? cancelNative;
  final _cancellations = <String, void Function()>{};
  final Duration nativeDelay, directTimeout, nativeTimeout;
  final DateTime Function() now;
  final _cache = <String, ({String url, DateTime expires})>{};
  final _pending = <String, ({Future<String> future, bool refresh})>{};
  bool _disposed = false;

  Future<String> resolve(
    String id, {
    bool refresh = false,
    bool speculative = false,
  }) async {
    if (_disposed) throw StateError('Stream resolver is closed.');
    if (refresh) _cache.remove(id);
    final cached = _cache[id];
    if (cached != null && now().isBefore(cached.expires)) {
      AudioDiagnostics.log('resolve.cache', 'track=$id');
      return cached.url;
    }
    final pending = _pending[id];
    if (pending != null && (!refresh || pending.refresh)) return pending.future;
    final request = _firstAvailable(
      id,
      nativeOnly: refresh,
      allowNative: !speculative,
    );
    _pending[id] = (future: request, refresh: refresh);
    try {
      final url = await request;
      if (!_disposed && identical(_pending[id]?.future, request)) {
        final expiration = int.tryParse(
          Uri.parse(url).queryParameters['expire'] ?? '',
        );
        var expires = now().add(const Duration(minutes: 10));
        if (expiration != null) {
          final signedExpiry = DateTime.fromMillisecondsSinceEpoch(
            expiration * 1000,
          ).subtract(const Duration(minutes: 1));
          if (signedExpiry.isBefore(expires)) expires = signedExpiry;
        }
        _cache.remove(id);
        if (_cache.length >= 30) _cache.remove(_cache.keys.first);
        _cache[id] = (url: url, expires: expires);
      }
      return url;
    } finally {
      if (identical(_pending[id]?.future, request)) _pending.remove(id);
    }
  }

  Future<String> _firstAvailable(
    String id, {
    required bool nativeOnly,
    required bool allowNative,
  }) async {
    final result = Completer<String>();
    var directDone = nativeOnly;
    var nativeDone = native == null || !allowNative;
    var nativeStarted = false, cancellationSent = false;
    Timer? hedge;
    void cancel() {
      hedge?.cancel();
      if (nativeStarted &&
          !nativeDone &&
          !cancellationSent &&
          cancelNative != null) {
        cancellationSent = true;
        unawaited(cancelNative!(id).catchError((Object _) {}));
      }
      if (_disposed && !result.isCompleted) {
        result.completeError(StateError('Stream resolver is closed.'));
      }
    }

    _cancellations[id] = cancel;
    void failIfFinished() {
      if (!result.isCompleted && directDone && nativeDone) {
        result.completeError(StateError('No stream is currently available.'));
      }
    }

    Future<void> attempt(
      Future<String?> Function(String) lookup,
      bool isNative,
    ) async {
      final timer = Stopwatch()..start();
      final provider = isNative ? 'native' : 'direct';
      AudioDiagnostics.log(
        'resolve.start',
        'track=$id provider=$provider refresh=$nativeOnly',
      );
      try {
        final url = await lookup(
          id,
        ).timeout(isNative ? nativeTimeout : directTimeout);
        final uri = url == null ? null : Uri.tryParse(url);
        if (uri != null &&
            (uri.scheme == 'https' || uri.scheme == 'http') &&
            uri.host.isNotEmpty) {
          AudioDiagnostics.log(
            'resolve.ready',
            'track=$id provider=$provider ms=${timer.elapsedMilliseconds} winner=${!result.isCompleted}',
          );
          if (!result.isCompleted) result.complete(url!);
        } else {
          AudioDiagnostics.log(
            'resolve.unavailable',
            'track=$id provider=$provider ms=${timer.elapsedMilliseconds}',
          );
        }
      } catch (error) {
        if (isNative &&
            error is TimeoutException &&
            !cancellationSent &&
            cancelNative != null) {
          cancellationSent = true;
          unawaited(cancelNative!(id).catchError((Object _) {}));
        }
        AudioDiagnostics.log(
          'resolve.failed',
          'track=$id provider=$provider ms=${timer.elapsedMilliseconds} error=$error',
        );
        // Failure of one candidate must not discard the other candidate.
      } finally {
        if (isNative) {
          nativeDone = true;
        } else {
          directDone = true;
        }
        failIfFinished();
      }
    }

    void startNative() {
      if (nativeStarted || result.isCompleted) return;
      if (_disposed || native == null || !allowNative) {
        nativeDone = true;
        failIfFinished();
        return;
      }
      nativeStarted = true;
      unawaited(attempt(native!, true));
    }

    if (!nativeOnly) {
      unawaited(
        attempt(direct, false).then((_) {
          if (!result.isCompleted) {
            hedge?.cancel();
            startNative();
          }
        }),
      );
      if (native != null && allowNative) {
        hedge = Timer(nativeDelay, startNative);
      }
    } else {
      startNative();
      failIfFinished();
    }
    try {
      return await result.future;
    } finally {
      cancel();
      if (identical(_cancellations[id], cancel)) _cancellations.remove(id);
    }
  }

  void dispose() {
    _disposed = true;
    for (final cancel in _cancellations.values.toList()) {
      cancel();
    }
    _cancellations.clear();
    _cache.clear();
  }
}
