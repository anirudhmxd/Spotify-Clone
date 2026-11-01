import 'dart:async';
import 'audio_diagnostics.dart';

/// Caches short-lived direct URLs and shares pending metadata requests.
class StreamResolver {
  StreamResolver({
    required this.direct,
    DateTime Function()? now,
    this.timeout = const Duration(seconds: 5),
  }) : now = now ?? DateTime.now;

  final Future<String?> Function(String) direct;
  final DateTime Function() now;
  final Duration timeout;
  final _cache = <String, ({String url, DateTime expires})>{};
  final _pending = <String, Future<String>>{};
  bool _disposed = false;

  Future<String> resolve(String id, {bool refresh = false}) async {
    if (_disposed) throw StateError('Stream resolver is closed.');
    if (refresh) _cache.remove(id);
    final cached = _cache[id];
    if (cached != null && now().isBefore(cached.expires)) {
      AudioDiagnostics.log('resolve.cache', 'track=$id');
      return cached.url;
    }
    final pending = _pending[id];
    if (pending != null) {
      AudioDiagnostics.log('resolve.shared_pending', 'track=$id');
      return pending;
    }
    final request = _resolve(id);
    _pending[id] = request;
    try {
      final url = await request;
      if (_disposed) throw StateError('Stream resolver is closed.');
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
      if (_cache.length >= 30) _cache.remove(_cache.keys.first);
      _cache[id] = (url: url, expires: expires);
      return url;
    } finally {
      if (identical(_pending[id], request)) _pending.remove(id);
    }
  }

  Future<String> _resolve(String id) async {
    final clock = Stopwatch()..start();
    AudioDiagnostics.log('resolve.start', 'track=$id provider=youtube_explode');
    try {
      final url = await direct(id).timeout(timeout);
      final uri = url == null ? null : Uri.tryParse(url);
      if (uri == null ||
          !['https', 'http'].contains(uri.scheme) ||
          uri.host.isEmpty) {
        throw StateError('No audio stream is currently available.');
      }
      AudioDiagnostics.log(
        'resolve.ready',
        'track=$id ms=${clock.elapsedMilliseconds}',
      );
      return url!;
    } catch (error) {
      AudioDiagnostics.log(
        'resolve.failed',
        'track=$id ms=${clock.elapsedMilliseconds} error=$error',
      );
      rethrow;
    }
  }

  void dispose() {
    _disposed = true;
    _cache.clear();
  }
}
