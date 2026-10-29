import 'package:flutter/material.dart';

import 'music_controller.dart';
import 'services/audio_engine.dart';
import 'services/device_music_repository.dart';
import 'widgets/music_shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MusicApp(
      controller: MusicController(DeviceMusicRepository(), JustAudioEngine()),
    ),
  );
}

class MusicApp extends StatefulWidget {
  final MusicController controller;
  const MusicApp({super.key, required this.controller});
  @override
  State<MusicApp> createState() => _MusicAppState();
}

class _MusicAppState extends State<MusicApp> {
  @override
  void initState() {
    super.initState();
    widget.controller.loadLibrary();
  }

  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Spotify — Your music',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xff080808),
      colorScheme: const ColorScheme.dark(
        primary: Color(0xff1ed760),
        secondary: Color(0xff1ed760),
        surface: Color(0xff121212),
      ),
      useMaterial3: true,
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xff242424),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(28),
          borderSide: BorderSide.none,
        ),
      ),
    ),
    home: MusicShell(controller: widget.controller),
  );
}
