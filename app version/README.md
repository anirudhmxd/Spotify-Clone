# Spotify Flutter app — on device

A standalone Flutter app for Android, iOS, and macOS. All application logic runs in Dart on the device. Search and audio connect directly to YouTube over HTTPS. Playlists, listening counts, recommendations, and downloaded audio stay in local device storage.

No backend service, Python, yt-dlp, FFmpeg, JavaScript runtime, API key, server address, or second terminal is needed.

## Run

Use Flutter stable with Dart 3.11 or newer, plus the normal Android SDK or Xcode tools for your target.

```sh
flutter pub get
flutter devices
flutter run
```

Select your Android device/emulator or iOS simulator. On macOS:

```sh
flutter run -d macos
```

Internet access is needed for YouTube search and streaming. Downloaded songs can play offline from saved playlists and Songs For You. The native app is the supported target; browser access to YouTube would require a proxy because of browser cross-origin restrictions, so this project does not include a web runner.

## Features

- Responsive sidebar on larger displays and bottom navigation on phones.
- Debounced YouTube song/artist search and playlist URLs; cancellation, timeouts, stale-response protection, and pagination.
- Direct HTTPS audio playback with previous/next, repeat, seeking, volume, mute, and persistent player controls.
- Local playlists: create, delete, add/remove tracks, artwork, duration totals, and play/pause.
- Songs For You ranks listening counts on this device. Each play counts once after reaching 85% of the song. Queue continuation uses this local listening history.
- Downloads save audio as M4A in the app's Documents/downloads directory. A **Save / Share** action opens the native share sheet to export the file. Downloads stream to a temporary file, verify the expected size, and only then become available for offline playback.
- Local library writes are serialized and use a temporary file plus a recovery backup.

The app keeps its own library; it does not sync with the original website's Python files. YouTube media URLs are resolved afresh when needed and are not saved as permanent playback URLs. YouTube restrictions or upstream changes can make individual tracks unavailable; the app reports failures without blocking navigation.

## Build and verify

```sh
flutter analyze
flutter test
flutter build apk
flutter build macos
# On a Mac with full Xcode:
flutter build ios --no-codesign
```

The automated tests cover local persistence across repository restarts, concurrent play counts, corruption recovery, playlist edits, offline file selection, duplicate downloads, local recommendations, search races, timeouts, pagination retries, audio-loading races, and phone/tablet/desktop layouts.

Optional live check of direct YouTube search, audio URL resolution, and media byte delivery:

```sh
dart run tool/check_youtube.dart
```

Verified with Flutter 3.47.8: all 17 automated tests passed, analysis reported no issues, the native Dart asset bundle compiled, and the live direct-search/audio/byte-delivery check passed.

Native application binaries and device playback require the corresponding platform SDKs and have not been verified on this machine.

## Source

- `lib/services/youtube_catalog.dart`: direct YouTube search, playlist discovery, audio resolution, streaming downloads, and cancellation.
- `lib/services/library_store.dart`: device-local JSON library with serialized writes and recovery.
- `lib/services/device_music_repository.dart`: combines the local library and direct catalog; prefers downloaded audio for playback.
- `lib/services/music_repository.dart`: typed interface for the controller and tests.
- `lib/services/audio_engine.dart`: Flutter audio adapter, with its optional local HTTP header proxy disabled.
- `lib/music_controller.dart`: screen state, search, queue, playback, downloads, and listening counts.
- `lib/widgets/`: native Flutter screens and player controls.

Direct YouTube access uses [youtube_explode_dart](https://pub.dev/packages/youtube_explode_dart). Audio uses [just_audio](https://pub.dev/packages/just_audio), local directories use [path_provider](https://pub.dev/packages/path_provider), and file export uses [share_plus](https://pub.dev/packages/share_plus).
