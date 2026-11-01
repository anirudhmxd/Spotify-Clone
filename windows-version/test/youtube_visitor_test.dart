import 'dart:convert';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
// Exercise the app-owned extraction patch without making network requests.
// ignore: implementation_imports
import 'package:youtube_explode_dart/src/videos/video_controller.dart';

class _Http extends YoutubeHttpClient {
  int visitorRequests = 0;
  Completer<void>? gate;
  bool failVisitor = false;
  final bodies = <Map<String, dynamic>>[];
  final requestHeaders = <Map<String, String>>[];
  @override
  Future<String> getString(
    dynamic url, {
    Map<String, String> headers = const {},
    bool validate = true,
  }) async {
    expect(url.toString(), endsWith('/sw.js_data'));
    visitorRequests++;
    await gate?.future;
    if (failVisitor) throw StateError('Visitor lookup failed');
    final fields = List<dynamic>.filled(14, null)..[13] = 'session-visitor';
    final data = jsonEncode([
      [
        null,
        null,
        [
          [fields],
        ],
      ],
    ]);
    return ")]}'$data";
  }

  @override
  Future<String> postString(
    dynamic url, {
    Map<String, dynamic>? body,
    Map<String, String> headers = const {},
    bool validate = true,
  }) async {
    bodies.add(jsonDecode(jsonEncode(body)) as Map<String, dynamic>);
    requestHeaders.add(headers);
    return jsonEncode({
      'playabilityStatus': {'status': 'OK'},
      'videoDetails': {'videoId': 'seed0000001'},
    });
  }
}

void main() {
  test('concurrent lookups share the same visitor handshake', () async {
    final http = _Http()..gate = Completer<void>();
    final controller = VideoController(http);
    try {
      final first = controller.getPlayerResponse(
        VideoId('seed0000001'),
        YoutubeApiClient.visionOs,
      );
      final second = controller.getPlayerResponse(
        VideoId('seed0000002'),
        YoutubeApiClient.visionOs,
      );
      expect(http.visitorRequests, 1);
      http.gate!.complete();
      await Future.wait([first, second]);
      expect(http.visitorRequests, 1);
      expect(http.bodies.length, 2);
    } finally {
      http.close();
    }
  });
  test('failed visitor handshake can be retried by the next track', () async {
    final http = _Http()..failVisitor = true;
    final controller = VideoController(http);
    try {
      await expectLater(
        controller.getPlayerResponse(
          VideoId('seed0000001'),
          YoutubeApiClient.visionOs,
        ),
        throwsStateError,
      );
      http.failVisitor = false;
      await controller.getPlayerResponse(
        VideoId('seed0000002'),
        YoutubeApiClient.visionOs,
      );
      expect(http.visitorRequests, 2);
    } finally {
      http.close();
    }
  });
  test(
    'visionOS gets visitor data once and does not mutate its shared profile',
    () async {
      final http = _Http();
      final controller = VideoController(http);
      final profile = YoutubeApiClient.visionOs;
      final before = jsonEncode(profile.payload);
      try {
        for (final id in ['seed0000001', 'seed0000002']) {
          await controller.getPlayerResponse(VideoId(id), profile);
        }
        expect(http.visitorRequests, 1);
        expect(http.bodies.map((b) => b['context']['client']['visitorData']), [
          'session-visitor',
          'session-visitor',
        ]);
        expect(http.bodies.map((b) => b['context']['client']['clientName']), [
          'VISIONOS',
          'VISIONOS',
        ]);
        expect(http.requestHeaders.first['User-Agent'], contains('Safari'));
        expect(jsonEncode(profile.payload), before);
      } finally {
        http.close();
      }
    },
  );
  test('separate sessions get their own visitor data', () async {
    final first = _Http(), second = _Http();
    try {
      await VideoController(
        first,
      ).getPlayerResponse(VideoId('seed0000001'), YoutubeApiClient.visionOs);
      await VideoController(
        second,
      ).getPlayerResponse(VideoId('seed0000002'), YoutubeApiClient.visionOs);
      expect(first.visitorRequests, 1);
      expect(second.visitorRequests, 1);
    } finally {
      first.close();
      second.close();
    }
  });
}
