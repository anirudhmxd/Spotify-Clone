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
- Download fallbacks on Android, macOS and the Python worker use four concurrent fragments for DASH/HLS, 1 MiB HTTP chunks, a ten-second socket timeout and three retries. Missing fragments abort rather than silently producing incomplete offline audio. Progressive HTTP concurrency is implemented in the app's `AudioFileDownloader`; yt-dlp's fragment option alone does not parallelize progressive files.

Actual Android playback and native compilation require the Android SDK/device. Dart tests exercise the stream race, cache, preparation, and retry behavior; they are not a device latency benchmark.

## Runtime packaging and diagnostics

- The app's iOS Podfile explicitly prepares the local ytdlp plugin, and Runner packages Python in a final build phase. The installer validates runtime inputs, copies the current worker on every build, and uses POSIX-compatible path stripping for extension modules.
- Optional Android and embedded Python diagnostics expose extraction stages, retry/update events and transfer progress. The Dart bridges pass the `AUDIO_DIAGNOSTICS` setting; signed URLs are removed before diagnostic output.
- Setup references: https://guides.cocoapods.org/syntax/podspec.html#prepare_command and https://docs.python.org/3/using/ios.html#adding-python-to-an-ios-project.

## Android 50-second download investigation

- Bundled official yt-dlp 2026.10.26 (SHA-256 `e51e69e89489f199530f13d32a4342da3ddb2cf34842f364603a066db05afbf3`) replaces the wrapper's old initial extractor without a phone-side network fetch. Installation is atomic and preserves newer runtime updates. License/provenance travel with the asset.
- Optional task IDs on `resolveAudio` enable cancellation. Android registers lookup IDs before initialization, watches the eight-second deadline and repeatedly terminates cancelled processes until registration/exit. Lookup failures do not trigger updates; full-download update retries happen only after a changed engine.
- Native extraction uses a private cache rather than the wrapper's default `--no-cache-dir`. App preparation avoids speculative native processes; playback failures do not repeat the same timed-out resolver cycle in file fallback.
- Wrapper source/API checked against the published 0.18.1 source archive from Maven Central. Regression tests include compiled Kotlin using API fakes; the full APK/device test still requires Android SDK/Gradle tooling.
