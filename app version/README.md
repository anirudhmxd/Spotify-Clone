# Rhythm app

A standalone Flutter music app for Android, iOS, and macOS. This directory contains the native app; the web version lives separately in `../WEB-version`.

## Listening and discovery

- Search for a song or artist, or paste a YouTube playlist link. Recent result pages are cached for five minutes; typed searches wait 180 ms for a pause in typing.
- Playing a search result starts with that song. With **Autoplay** enabled, the queue fills with related songs, excluding the seed and duplicate editions. Explicit playlists retain their order.
- **Made for you** finds related music from the current song, recent listening, or liked songs. If YouTube's related-song endpoint is unavailable, discovery falls back to other songs by the seed artist, then matching songs in the local library. Offline suggestions use downloaded songs only.
- Playback uses cached audio first, then an AAC stream. If stream extraction or loading fails, the app falls back to a native-container download. Network failures have bounded waits; failed downloads can be retried. Explicit downloads remain available offline.
- Play buttons show a contrasting loading ring and stop icon while resolving audio. Tap again to cancel playback of that selection.

## Development and checks

Use Flutter with Dart 3.11 or later, then run:

```sh
flutter pub get
flutter analyze
flutter test
flutter test tool/preview_test.dart
```

Preview renders are written to `build/previews/` at phone and desktop sizes. They use test data, not a live music account.

Optional live catalog check (requires internet):

```sh
flutter test tool/catalog_live_test.dart --dart-define=LIVE_CATALOG=true
```

Native builds require the platform's development tools. macOS and iOS require full Xcode and CocoaPods; Android requires the Android SDK. Stream availability, search latency, and recommendation availability depend on YouTube and the device's network. A successful catalog check does not replace testing audio output on a physical device.
