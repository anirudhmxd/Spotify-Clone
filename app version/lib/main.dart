import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'services/media_controls.dart';

import 'music_controller.dart';
import 'brand.dart';
import 'services/audio_engine.dart';
import 'services/device_music_repository.dart';
import 'widgets/music_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = MusicController(
    DeviceMusicRepository(),
    JustAudioEngine(),
  );
  String? startupMessage;
  try {
    await AudioService.init(
      builder: () => DeviceMediaHandler(controller),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.localmusic.playback',
        androidNotificationChannelName: 'Rhythm playback',
        androidNotificationIcon: 'drawable/ic_stat_rhythm',
        androidStopForegroundOnPause: false,
      ),
    );
    await (await AudioSession.instance).configure(
      const AudioSessionConfiguration.music(),
    );
  } catch (_) {
    startupMessage =
        'Device media controls could not start. In-app playback is still available.';
  }
  runApp(MusicApp(controller: controller));
  if (startupMessage != null) {
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => controller.message(startupMessage!),
    );
  }
}

class MusicApp extends StatefulWidget {
  final MusicController controller;
  const MusicApp({super.key, required this.controller});
  @override
  State<MusicApp> createState() => _MusicAppState();
}

class _MusicAppState extends State<MusicApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.loadLibrary();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) widget.controller.flushListening();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Rhythm — Your music',
    debugShowCheckedModeBanner: false,
    theme: RhythmBrand.theme,
    home: MusicShell(controller: widget.controller),
  );
}
