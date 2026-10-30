# App-owned dependency fixes

These copies are resolved through relative paths in the app's `pubspec.yaml`. They travel with source checkouts and Android/iOS/macOS builds; modifying a developer's package cache would not fix installed apps. Upstream licenses and package manifests are retained. Keep these patches when upgrading, or remove each copy once the corresponding upstream release includes an equivalent fix.

## youtube_explode_dart 3.1.0

Source: https://pub.dev/packages/youtube_explode_dart/versions/3.1.0

Runtime `lib/`, manifest, README and license copied without generated build artifacts. The original date-label patch in `lib/src/extensions/helpers_extension.dart` makes optional display dates accept abbreviated/long English units and Streamed/Premiered prefixes. Unknown labels return null rather than aborting an entire search, pagination request, or related-song list. Regressions live in the app's `test/youtube_date_test.dart`.

Direct audio download fixes in `lib/src/reverse_engineering/youtube_http_client.dart`:

- Clamp requested range ends to the known file size, including low-bitrate files smaller than the throttled-stream chunk size.
- Refresh a rejected stream URL once; persistent fatal HTTP errors propagate instead of looping through manifests without emitting bytes.
- Forward byte-stream errors and cancellation through `await for` instead of swallowing errors in an unbounded intermediate controller.

`test/youtube_transfer_test.dart` uses the real library byte-stream API against a local HTTP server to check both Range-header/query formats and persistent 403 behavior. `test/data_saving_downloader_test.dart` verifies low-bitrate selection, compatible file formats, exact sizes, timeouts and client/file cleanup.

### Playback client and visitor session

- Added the current visionOS cipherless playback profile from upstream YoutubeExplode's VideoController: https://github.com/Tyrrrz/YoutubeExplode/blob/master/YoutubeExplode/Videos/VideoController.cs.
- Use it by default before Android SDK-less/TV fallbacks. Resolve session visitor data for visionOS as well as iOS; copy nested player context before adding it instead of mutating shared profile maps.
- Audio downloads request a cipherless manifest without an extra watch page. `test/youtube_visitor_test.dart` checks visitor caching, separate sessions and immutable shared configuration. Complete live downloads verify actual bytes, not just a successful HEAD or first chunk.

### Shared visitor handshake

`VideoController` now shares an in-flight visitor lookup across concurrent manifests. Successful visitor data remains session-local; failures release the pending request so a later track can retry. The app reuses a metadata client across audio lookups. Regressions in `test/youtube_visitor_test.dart` and `test/audio_lookup_session_test.dart` cover concurrent handshakes, session replacement, disposal and bounded preparation.

### Audio-only lookup

`StreamClient.getManifest` accepts optional `audioOnly` and `validateStreams` arguments. The app enables audio-only parsing and skips the preliminary HEAD check. Direct audio avoids parsing video formats (and their missing-size requests) and fetching additional DASH/HLS manifests; those manifests remain fallbacks when no direct audio is available. Actual media requests retain HTTP validation. Defaults preserve full manifests and HEAD validation for other callers. `test/audio_manifest_test.dart` verifies request counts, session reuse, default validation and manifest fallback.

## just_audio 0.10.6

Source: https://pub.dev/packages/just_audio/versions/0.10.6. Runtime Dart/Android/shared Darwin sources, package metadata and license are included without examples or generated artifacts.

- `AudioPlayer.setRhythmEqualizer` stores settings while idle and reapplies them when native playback activates. It sends live control changes to the current native player without a source reload. `rhythmWaveform` fetches measured PCM samples only while requested.
- Android's Media3 1.4.1 `DefaultAudioSink` adds `RhythmAudioProcessor`, with five peaking filters in `RhythmDsp`. The sink uses its normal 16-bit PCM conversion path. No system-wide EQ or recording permission is needed.
- Shared Darwin `AudioPlayer` attaches `RhythmEqualizer` when an item becomes ready. A MediaToolbox processing tap applies `RhythmDSP` to that item's PCM, including progressive AAC streams and saved files. Context ownership follows tap initialization/finalization; target gains and visualization data use atomics, and the render callback does not allocate or lock.
- Both paths retain independent channel filter state, bound gains to ±12 dB, smooth gain changes, reserve positive-boost headroom, protect output peaks, and bypass flat filtering. Visualization samples come after filtering and are disabled when the UI is not observing them.
- CocoaPods and Swift Package Manager both link the Apple audio frameworks. Existing source load, clipping, buffer settings and background media controls remain in the player.

Primary API references: [Apple processing taps](https://developer.apple.com/documentation/mediatoolbox/mtaudioprocessingtap), [Media3 AudioProcessor](https://developer.android.com/reference/androidx/media3/common/audio/AudioProcessor), [Media3 renderer audio-sink extension](https://github.com/androidx/media/blob/1.4.1/libraries/exoplayer/src/main/java/androidx/media3/exoplayer/DefaultRenderersFactory.java).
