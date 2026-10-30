# Rhythm app

A standalone Flutter music app for Android, iOS, and macOS. This directory contains the native app; the web version lives separately in `../WEB-version`.

## Listening and discovery

- Search for a song or artist, or paste a YouTube playlist link. Recent result pages are cached for five minutes; typed searches wait 180 ms for a pause in typing.
- Playing a search result starts with that song. With **Autoplay** enabled, the queue fills with related songs, excluding the seed and duplicate editions. Explicit playlists retain their order.
- **Made for you** finds related music from the current song, recent listening, or liked songs. If YouTube's related-song endpoint is unavailable, discovery falls back to other songs by the seed artist, then matching songs in the local library. Offline suggestions use downloaded songs only.
- Playback uses cached audio first, then an AAC stream. Android races a slow direct extractor with native metadata-only extraction after 800 ms; a rejected stream gets a fresh native URL before falling back to a full download. A failure on one track no longer disables streaming for other tracks.
- The top search result and the next queued song can have their stream URL prepared in advance (one background preparation at a time, no full-song speculative downloads, disabled offline). Playback reuses these short-lived URLs and in-flight requests.
- Android starts with 350 ms of buffered audio and continues building a 15–45 second reserve. Playback progress updates at most five times a second; the app paints before media-control setup completes. Library reads reuse an in-memory snapshot while writes still persist atomically with a backup.
- Optional YouTube date labels such as `Streamed 3y ago` are parsed safely. Unknown dates no longer abort search results. The app-owned dependency patches are documented in `third_party/PATCHES.md` and included in fresh builds.
- Play buttons show a contrasting loading ring and stop icon while resolving audio. Tap again to cancel playback of that selection.

## Offline download performance

- Downloads reuse prepared and in-flight audio URLs, avoiding a second extractor invocation when a usable link is already available. AAC/MP4 files transfer directly without transcoding.
- Range-capable servers use up to three connections per song, fetching 512 KiB blocks. Servers that ignore ranges use one streamed transfer. Every range and the final file length are checked; partial files are never published as offline songs.
- At most two songs download at once. **Download all** skips duplicate/already saved songs and refreshes the library once after the batch, rather than scanning every saved file after every song. Speculative stream preparation pauses during downloads.
- Rejected direct links fall back to the native downloader, with four concurrent fragments for segmented sources, 1 MiB HTTP chunks, and bounded retries. Timed-out native tasks are cancelled before retrying.

Actual speed depends on the source, network and device. The automated download tests use a local server to verify concurrent transfers, exact file contents, range rejection, timeout cleanup and playlist queue behavior.

## Background music controls (Android)

Start a song, then press Home or lock the screen. The media notification shows the song, artist, artwork, previous/play-pause/next controls, and a seek bar where supported by the Android version. Tapping the notification opens Rhythm. Playback and controls remain active when the activity is backgrounded; stopping playback dismisses the active notification. No separate notification-access permission is needed for this media-session notification.

After installing a new build, verify on an Android device: play a song, background the app, pause/resume from the notification, skip both directions, seek, lock/unlock the phone, and tap the notification to reopen the app. Also check a slow-loading song and release-build notification icons. Force-stopping the app in Android settings terminates playback.

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

Optional complete-file download check (downloads the same audio with one and three connections and compares all bytes):

```sh
flutter test tool/download_live_test.dart --dart-define=LIVE_DOWNLOAD=true
```

Use `--dart-define=VIDEO_ID=<id>` to choose another test video. This is a live diagnostic, not a guaranteed speedup benchmark; it deliberately fails when extraction or complete download is unavailable.

Rebuild and reinstall the native app to apply these changes; existing installed APKs do not pick up source edits.

Native builds require the platform's development tools. macOS and iOS require full Xcode and CocoaPods; Android requires the Android SDK. Stream availability, search latency, and recommendation availability depend on YouTube and the device's network. A successful catalog check does not replace testing audio output on a physical device.

## iOS runtime packaging

The Runner target includes a final **Install Python runtime** build phase. It copies the SDK-matching Python standard library, current worker, yt-dlp zipapp and certificates into the app, converts extension modules to frameworks and signs them with the app identity. The Podfile explicitly prepares the local plugin dependencies (CocoaPods does not run `prepare_command` for path pods) and keeps this phase last after integration. Missing runtime inputs now fail the build rather than causing `NO_STDLIB` during playback.

After pulling this change, run `flutter pub get`, run `pod install` in `ios/`, then rebuild/reinstall with `flutter run`. Hot reload cannot add native bundle resources. The first pod installation downloads the Python framework and audio engine; subsequent installs reuse them. Full Xcode, CocoaPods and device signing are required for an iPhone build.

The fixture check `python3 tool/test_ios_packaging.py` exercises device/simulator layouts, binary-module relocation, incremental builds, and missing-input failures. It does not compile or validate signing on a real iPhone.

## Audio diagnostics

Debug/profile runs enable console diagnostics by default. Use `flutter run --dart-define=AUDIO_DIAGNOSTICS=true` explicitly when collecting a report, or `--dart-define=AUDIO_DIAGNOSTICS=false` to disable them. Release builds default to disabled.

Reproduce with a song that is not already cached. Copy the output from the play/download tap through success or failure, including `[AUDIO`, `RhythmAudio`, `[AUDIO-PYTHON]`, `[YTDLP]`, and player errors. Include Wi-Fi/mobile-data and VPN status. No need to delete your library.

Logs distinguish cached URLs, each extractor's time/result, queue wait, HTTP status, direct-transfer bytes/speed, native progress/ETA, extractor updates/retries, and source-load failures. Native Android output retains yt-dlp's speed and retry messages; the Apple Python worker logs bytes/speed and extraction warnings. Progress is sampled about every two seconds. Signed URLs are redacted and request headers/cookies are not logged by these diagnostics. A `native.start` to `native.complete` interval includes extraction and retries, not just file transfer; `play.loaded` means the player accepted its source, not a measured first audible sample.
