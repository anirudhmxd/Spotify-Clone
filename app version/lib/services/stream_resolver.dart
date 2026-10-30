import 'dart:async';

/// Races metadata-only extractors; never downloads a complete media file.
/// One stalled provider cannot hold up an already available stream.
class StreamResolver {
  StreamResolver({
    required this.direct,
    this.native,
    this.nativeDelay = const Duration(milliseconds: 800),
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  final Future<String?> Function(String) direct;
  final Future<String?> Function(String)? native;
  final Duration nativeDelay;
  final DateTime Function() now;
  final _cache = <String, ({String url, DateTime expires})>{};
  final _pending = <String, ({Future<String> future, bool refresh})>{};
  bool _disposed = false;

  Future<String> resolve(String id, {bool refresh = false}) async {
    if (_disposed) throw StateError('Stream resolver is closed.');
    if (refresh) _cache.remove(id);
    final cached = _cache[id];
    if (cached != null && now().isBefore(cached.expires)) return cached.url;
    final pending = _pending[id];
    if (pending != null && (!refresh || pending.refresh)) return pending.future;
    final request = _firstAvailable(id, nativeOnly: refresh);
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

  Future<String> _firstAvailable(String id, {required bool nativeOnly}) async {
    final result = Completer<String>();
    var directDone = nativeOnly;
    var nativeDone = native == null;
    var nativeStarted = false;
    Timer? hedge;
    void failIfFinished() {
      if (!result.isCompleted && directDone && nativeDone) {
        result.completeError(StateError('No stream is currently available.'));
      }
    }

    Future<void> attempt(
      Future<String?> Function(String) lookup,
      bool isNative,
    ) async {
      try {
        final url = await lookup(
          id,
        ).timeout(Duration(seconds: isNative ? 12 : 5));
        final uri = url == null ? null : Uri.tryParse(url);
        if (uri != null &&
            (uri.scheme == 'https' || uri.scheme == 'http') &&
            uri.host.isNotEmpty) {
          if (!result.isCompleted) result.complete(url!);
        }
      } catch (_) {
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
      if (_disposed || native == null) {
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
      if (native != null) hedge = Timer(nativeDelay, startNative);
    } else {
      startNative();
      failIfFinished();
    }
    try {
      return await result.future;
    } finally {
      hedge?.cancel();
    }
  }

  void dispose() {
    _disposed = true;
    _cache.clear();
  }
}
