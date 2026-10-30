import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp_flutter/ytdlp_flutter.dart';
// Verify the Android bridge without loading native binaries in widget tests.
// ignore: implementation_imports
import 'package:ytdlp_flutter/src/ytdlp_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Android stream bridge asks for a URL without starting a download',
    () async {
      const channel = MethodChannel('ytdlp_flutter');
      final original = YtdlpPlatform.instance;
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return 'https://audio.example/native.m4a';
          });
      YtdlpPlatform.instance = MethodChannelYtdlp();
      try {
        expect(
          await Ytdlp.resolveAudio(
            'https://www.youtube.com/watch?v=seed0000001',
          ),
          'https://audio.example/native.m4a',
        );
        expect(calls.single.method, 'resolveAudio');
        expect(calls.single.arguments, {
          'url': 'https://www.youtube.com/watch?v=seed0000001',
          'diagnostics': true,
        });
      } finally {
        YtdlpPlatform.instance = original;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      }
    },
  );
}
