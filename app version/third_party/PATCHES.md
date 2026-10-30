# App-owned dependency fixes

These copies are resolved through relative paths in the app's `pubspec.yaml`. They travel with source checkouts and Android/iOS/macOS builds; modifying a developer's package cache would not fix installed apps. Upstream licenses and package manifests are retained. Keep these patches when upgrading, or remove each copy once the corresponding upstream release includes an equivalent fix.

## youtube_explode_dart 3.1.0

Source: https://pub.dev/packages/youtube_explode_dart/versions/3.1.0

Runtime `lib/`, manifest, README and license copied without generated build artifacts. Changed only `lib/src/extensions/helpers_extension.dart`: optional display dates now accept abbreviated/long English units and Streamed/Premiered prefixes. Unknown labels return null rather than aborting an entire search, pagination request, or related-song list. Regressions live in the app's `test/youtube_date_test.dart`.

## ytdlp_flutter 0.1.0

Source: https://pub.dev/packages/ytdlp_flutter/versions/0.1.0

Runtime platform sources, Python worker, manifest, README and license retained. Changes:

- Optional `Ytdlp.resolveAudio` API, with a default unsupported result on existing non-Android backends.
- Android `resolveAudio` uses native yt-dlp to select a direct AAC/M4A audio URL without downloading media. Socket timeouts and retries are bounded.
- Android initialization no longer waits for a network extractor update or unpacks unused FFmpeg. An extraction failure can trigger one update and retry per process; explicit update remains available. FFmpeg initializes only for requested transcoding.

Actual Android playback and native compilation require the Android SDK/device. Dart tests exercise the stream race, cache, preparation, and retry behavior; they are not a device latency benchmark.
