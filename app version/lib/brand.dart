import 'package:flutter/material.dart';

/// Shared Rhythm identity for every screen and playback surface.
abstract final class RhythmBrand {
  static const name = 'Rhythm';
  static const background = Color(0xff090b12);
  static const surface = Color(0xff11141f);
  static const raised = Color(0xff202334);
  static const violet = Color(0xffb58aff);
  static const pink = Color(0xffed8cf6);
  static const blue = Color(0xff7394ff);
  static const cyan = Color(0xff6bd6ff);
  static const ink = Color(0xff1b092f);
  static const pageTop = Color(0xff202039);
  static const logo = 'assets/branding/rhythm-original.png';
  static const icon = 'assets/branding/rhythm-icon.png';
  static const gradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xffc43cd9), Color(0xff7026dd), Color(0xff344ee7)],
  );
  static ThemeData get theme => ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: background,
    colorScheme: const ColorScheme.dark(
      primary: violet,
      onPrimary: ink,
      secondary: pink,
      onSecondary: ink,
      tertiary: cyan,
      onTertiary: ink,
      surface: surface,
      onSurface: Color(0xfff6efff),
      surfaceContainerHighest: raised,
      outline: Color(0xff68537e),
    ),
    useMaterial3: true,
    appBarTheme: const AppBarTheme(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
    ),
    navigationBarTheme: const NavigationBarThemeData(
      height: 68,
      backgroundColor: background,
      indicatorColor: Color(0xff543078),
      iconTheme: WidgetStatePropertyAll(
        IconThemeData(color: Color(0xfff6efff)),
      ),
    ),
    listTileTheme: const ListTileThemeData(
      selectedTileColor: Color(0xff28253e),
      selectedColor: violet,
      iconColor: Color(0xffb6b8cb),
      subtitleTextStyle: TextStyle(
        fontFamily: 'Roboto',
        color: Color(0xffa4a7bb),
        fontSize: 13,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        textStyle: const TextStyle(
          fontFamily: 'Roboto',
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: Color(0xff292c3b),
      thickness: 1,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: raised,
      contentTextStyle: TextStyle(color: Color(0xfff6efff)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: raised,
      contentPadding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(28),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(28),
        borderSide: const BorderSide(color: violet),
      ),
    ),
  );
}

class RhythmLogo extends StatelessWidget {
  final double size;
  const RhythmLogo({super.key, this.size = 40});
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(size * .18),
    child: Image.asset(
      RhythmBrand.icon,
      width: size,
      height: size,
      fit: BoxFit.contain,
      cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
      semanticLabel: 'Rhythm logo',
    ),
  );
}

class RhythmWordmark extends StatelessWidget {
  final double size;
  const RhythmWordmark({super.key, this.size = 22});
  @override
  Widget build(BuildContext context) => Text(
    'RHYTHM',
    style: TextStyle(
      fontSize: size,
      fontWeight: FontWeight.w700,
      letterSpacing: 3.5,
      color: const Color(0xfff5e8ff),
    ),
  );
}
