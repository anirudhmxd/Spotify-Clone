# Rhythm — on-device Flutter music app

A standalone app for Android, iOS, and macOS. Application logic runs in Dart on the device. Discovery and streaming connect directly to YouTube over HTTPS; imported files, downloaded audio, playlists, likes, preferences, and listening statistics live on the device. There are no subscription gates in this app.

No Python, `run_server.py`, backend, server address, yt-dlp, FFmpeg, separate JavaScript runtime, or API key is needed. Flutter's standard native platform runners and audio/file plugins provide access to the device.

This is an independent music app, not a complete replacement for Spotify's service. It does not provide Spotify's licensed catalog or bypass Spotify Premium. Spotify accounts, cloud sync, Connect, collaborative sessions, official Wrapped, licensed synchronized lyrics, podcast subscriptions, crossfade, normalization, and lossless streaming are not implemented. Artist pages show matching tracks already discovered or saved, with a search action for more. Recommendations use local listening history.

## Run

Use Flutter 3.47 or newer, with the Android SDK or full Xcode tools for your target platform.

```sh
flutter pub get
flutter devices
flutter run
# macOS:
flutter run -d macos
```

Search and streaming need internet access. Imported and downloaded audio can play without an internet connection. Enable **Settings → Offline mode** to search your local library and restrict playback to files stored on the device. There is no web runner because direct YouTube access from browsers would require a proxy.

## Implemented functionality

| Area | Available functionality |
| --- | --- |
| Navigation | Responsive Home, Search, library, liked songs, downloads/local files, history, artist view, Rhythm Replay, settings; sidebar on desktop and bottom navigation on phones |
| Search | Debounced queries, cancellation, timeouts, stale-response protection, result pagination, recent searches; YouTube playlists fetched in pages; save loaded results as a playlist |
| Playback | Play/pause, seek, previous/next, volume/mute, playback speed, shuffle, repeat off/all/one, full-screen player, persistent mini-player |
| Queue | View queue, play an item, add next/last, drag to reorder, remove items, clear upcoming songs; editing a saved playlist leaves the current queue intact |
| Device controls | Android media notification/service configuration, iOS background audio configuration, lock-screen/headset/Bluetooth play/pause/seek/skip callbacks via `audio_service` |
| Library | Persistent likes; create, rename, describe, pin, duplicate, delete and filter playlists; sort playlists; add/remove/reorder/sort songs; playlist duration and artwork |
| Offline audio | Download tracks or a playlist; manage downloaded files and storage total; import MP3/M4A/AAC/WAV/FLAC/OGG/Opus files; export downloaded M4A through the native share sheet |
| Preferences | Local profile name, autoplay, offline mode, private listening, volume, speed, streaming/download quality, Android equalizer presets, sleep timer/end-of-song timer |
| Listening | Recently played tracks, local most-played ranking, yearly listening minutes, plays, songs, artists, listening days, monthly chart, top artists/tracks, save/share Rhythm Replay |
| Data | Local JSON with serialized writes and atomic replacement plus recovery backup; export/import playlists and likes; clear listening history and searches |

Quality settings choose from the compatible audio streams offered by YouTube; available bitrates vary by track. They affect newly resolved streams and new downloads, not existing files. Equalizer presets use Android's native audio effect and are shown only on Android. Playback of imported formats depends on the device's audio decoder.

A recorded play begins when listening time is observed. Replay minutes use playback progress adjusted for speed; seeks, buffering, pauses and private sessions are excluded. Most-played ranking counts a song once per playback after listening to 85% of its media duration. Statistics begin with listening recorded in this app; old website counts cannot reconstruct historical listening minutes.

Library export includes playlist/like metadata, not audio files or personal listening history. Import merges lists with new identifiers and excludes local file references, which cannot be transferred by a JSON file. Audio imports are copied into the app's Documents/imports directory. Downloads use Documents/downloads and become available only after their expected file size is verified.

YouTube may restrict a track or change its service. Failures are reported without blocking navigation. Stream URLs are resolved when needed rather than saved permanently. App storage is independent of the original website.

## Validation and builds

```sh
flutter analyze
flutter test
flutter build apk
flutter build macos
# Full Xcode required:
flutter build ios --no-codesign
```

Tests exercise search races/timeouts, pagination retry, stale audio resolution, cancellation/resume, queue manipulation, repeat/autoplay, sleep timers, settings, private sessions and listening accuracy, Replay aggregation, playlist edits, local storage recovery, offline imports/downloads, export/import, device-control state, and layouts at 320, 800 and 1280 pixels.

Optional direct-network smoke test:

```sh
dart run tool/check_youtube.dart
```

Optional UI previews with explicitly synthetic test data (images in `build/previews/`):

```sh
flutter test tool/preview_test.dart
```

Verified with Flutter 3.47.8: 34 automated tests passed, analysis reported no issues, the native Dart bundle compiled, and direct YouTube search/audio delivery passed. Phone and desktop previews were also rendered and inspected. Native installable binaries, real device decoding, background audio, notification permissions, headset controls, equalizer effects, and native file/share dialogs still need verification with full platform SDKs and physical devices. The Android release configuration currently uses Flutter's debug signing key; a distributable release needs your own signing setup.

## Source map

- `lib/services/youtube_catalog.dart`: direct discovery, paged playlist browsing, audio resolution and downloads.
- `lib/services/library_store.dart`: local persistence, listening records and library import/export.
- `lib/services/device_music_repository.dart`: combines direct catalog and local storage; selects offline files.
- `lib/services/audio_engine.dart`: native audio, speed and Android equalizer. Local HTTP header proxy is disabled.
- `lib/services/media_controls.dart`: native media session actions and state.
- `lib/music_controller.dart`: search, queue, playback, settings, timers and listening measurement.
- `lib/models/experience.dart`: settings, listening records and Replay aggregation.
- `lib/widgets/`: native Flutter interface.

Packages: [youtube_explode_dart](https://pub.dev/packages/youtube_explode_dart), [just_audio](https://pub.dev/packages/just_audio), [audio_service](https://pub.dev/packages/audio_service), [audio_session](https://pub.dev/packages/audio_session), [file_selector](https://pub.dev/packages/file_selector), [path_provider](https://pub.dev/packages/path_provider), and [share_plus](https://pub.dev/packages/share_plus).

## Rhythm identity

The app uses the supplied Rhythm logo and a shared black/violet/pink/blue theme in `lib/brand.dart`. `assets/branding/rhythm-original.png` is the unchanged supplied artwork. `rhythm-icon.png` is a compact symbol variant made with the built-in image generation tool; native icon sizes are exported from it. Visible native app names and the Dart package are renamed to Rhythm. Existing native bundle/application identifiers are retained to preserve installed app storage.

The image-generation prompt is recorded in `assets/branding/README.md`.
