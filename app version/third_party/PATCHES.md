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
