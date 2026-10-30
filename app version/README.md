# Rhythm app

A standalone Flutter music app for Android, iOS, and macOS. This directory contains the native app; the web version lives separately in `../WEB-version`.

## Listening and discovery

- Search YouTube Music’s song catalog by song or artist. Video and playlist links are not imported through search. Recent result pages are cached for five minutes; typed searches wait 180 ms for a pause in typing.
- Playing a search result starts with that song. With **Autoplay** enabled, related songs fill the queue, excluding the seed and duplicate editions. Explicit playlists retain their order.
- **Made for you** finds related music from the current song, recent listening, or liked songs. Discovery can fall back to song-only searches by the seed artist and verified songs in the local library. Offline suggestions use downloaded songs only.
- Playback checks cached audio, then tries a direct audio URL from `youtube_explode_dart`. If playback rejects the URL, the app saves audio through the library's byte-stream API and plays the completed file.
- The first two search results and next queued song can have their direct URL prepared in advance. Preparation is bounded, stops while downloading, and never downloads speculative full songs.
- Optional YouTube date labels such as `Streamed 3y ago` are parsed safely. Unknown dates no longer abort search results. The app-owned dependency patch is documented in `third_party/PATCHES.md`.
- Play buttons show a contrasting loading ring and stop icon while resolving audio. Tap again to cancel playback of that selection.

## Data-saving audio downloads

`DataSavingDownloader` uses `YoutubeExplode.videos.streamsClient.getManifest` and `.get` directly. The app has no yt-dlp plugin, Python runtime, FFmpeg conversion, or custom parallel-range downloader.

The lowest-bitrate compatible audio-only stream is selected explicitly in ascending bitrate order. The package's `sortByBitrate()` currently sorts descending, so `.first` would select the highest bitrate. Android supports the smaller WebM/Opus option when available; iOS/macOS select AAC/MP4 for playback compatibility. AAC audio is saved as `.m4a`, WebM as `.webm`; bytes are never relabelled or transcoded. Lower bitrate intentionally reduces sound quality to save data. Metadata usage and available bitrates vary by video.

A fresh client owns each manifest/transfer pair and is closed after the job. There is no extra `videos.get` request because the app already knows the video's ID and title. ID-based filenames avoid collisions between songs with identical titles. The app retains its existing persistent cache/library directory; the standalone downloader falls back to Android app storage or the documents directory when no directory is supplied.

Downloads write `.part` files, verify exact expected size and container signatures, then rename the completed file into place. Errors, timeouts and disposal remove partial files. Concurrent requests for one song share a transfer, and at most two songs download at once. **Download all** skips duplicates/already saved songs and refreshes the library once per batch. Existing saved songs remain usable.

There is no native downloader fallback. YouTube can still reject extraction or stream requests; these errors are logged and shown as failures that can be retried. This source change does not guarantee a particular download time or remove source-side restrictions.

## Playback duration and background controls

Playback constructs a clipped source with its known catalog duration before the first player load, with one second for rounded metadata. It does not call `setClip` after loading, which would load the same remote audio again. A position safeguard handles missing native completion events. Progress and system-control positions stay within the displayed duration; the app pauses at the end before fetching recommendations, advances once, or applies repeat/sleep settings. Unknown catalog durations retain normal native completion. This handles a timer running into a silent tail, not silence inside a song.

On Android, start a song, then press Home or lock the screen. The media notification shows the song, artist, artwork and previous/play-pause/next controls, plus seeking where supported. Tapping it opens Rhythm. Verify backgrounding, pause/resume, skipping, seeking, lock/unlock, and notification icons on a device. Force-stopping the app terminates playback.

## Development and checks

Use Flutter with Dart 3.11 or later:

```sh
flutter pub get
flutter analyze
flutter test
flutter test tool/preview_test.dart
```

Preview renders use test data and are written to `build/previews/`.

Optional live checks (require internet):

```sh
flutter test tool/catalog_live_test.dart --dart-define=LIVE_CATALOG=true
flutter test tool/download_live_test.dart --dart-define=LIVE_DOWNLOAD=true
```

The download check saves a complete low-bitrate AAC file through the same downloader used by the app and validates its size. Use `--dart-define=VIDEO_ID=<id>` to choose another video. A successful live check does not replace testing audio output and performance on the target device.

After replacing the native plugin, run `flutter pub get`, run `pod install` in `ios/` or `macos/` when building those platforms, then fully rebuild/reinstall. Hot reload cannot remove an embedded native runtime from an existing app. The former Python installation phase has been removed from Runner. Android builds need the Android SDK; Apple builds need full Xcode and CocoaPods.

## Audio diagnostics

Debug/profile runs enable console diagnostics by default:

```sh
flutter run --dart-define=AUDIO_DIAGNOSTICS=true
```

Use `--dart-define=AUDIO_DIAGNOSTICS=false` to disable them. Release builds default to disabled. Reproduce using an uncached song and copy the `[AUDIO ...]` entries from the tap through completion/failure. Include network and VPN status.

Logs include URL lookup time, queue wait, manifest selection, selected bitrate/container/size, transferred bytes, completion time and failure reasons. Signed URLs are redacted. `play.loaded` means the player accepted its source, not a measured first audible sample. `play.end` helps diagnose duration problems. `play.lookup_ready`, `play.source_load_start`, `play.source_load_ready` and `play.source_load_failed` separate lookup time from player preparation; a source-load timing includes its duration boundary in the same operation.

## YouTube 403 client compatibility

The app-owned extractor now requests the visionOS playback profile with per-session visitor data, following the current upstream YoutubeExplode flow. This is a YouTube API profile and works from Android/iOS/macOS. The old Android SDK-less profile could return metadata but fail on the actual GET with HTTP 403; it remains a fallback only when the preferred profile cannot provide streams.

Visitor data is fetched once for each HTTP session. Player payloads are copied before adding it, so parallel requests cannot mutate the shared client configuration. Both direct playback URL resolution and audio downloads use this profile. The cipherless download manifest request skips the redundant watch-page fetch. The selected client and format tag appear in `download.selected` diagnostics without exposing signed links.

The complete-file live test defaults to the reported Faded video (`3Lo8HBwOrQM`). A local check downloaded all 1,301,761 bytes of its low-bitrate AAC stream in about 1.2 seconds after this patch. This timing is specific to the test network and does not replace verification on the target device.

## Faster streaming startup

Audio URL lookups share one metadata HTTP client, keeping the visitor session and connections warm across songs. Concurrent lookups share an in-flight visitor request; failures release that request for retry. A failed audio metadata session is closed and replaced without cancelling search. Metadata preparation is limited to two unique search results, or one next queued song, and shares pending work with an actual play tap. It never downloads speculative full songs.

Playback and downloads request an audio-only manifest. Video formats are skipped before parsing, avoiding their extra size lookups, and DASH/HLS manifests are skipped when direct audio is available. The preliminary stream HEAD check is omitted; the actual playback/download request still checks its response. Fresh metadata still requires the YouTube player API, plus a visitor handshake for a new session. Prepared or cached URLs avoid those requests until they expire.

iOS/macOS use a three-second preferred forward buffer and disable the player's automatic extra wait to minimize stalling. The player can start once ready instead of waiting for a larger estimated buffer; unstable connections may rebuffer more often. Actual source-loading latency still depends on the native player and network.

`resolve.shared_pending` shows a tap reusing preparation. `play.progress_started` records a player position of at least 100 ms after loading, avoiding near-zero position updates; this is a playback-clock measurement, not a microphone measurement of audible sound. For device timing, use `flutter run --profile --dart-define=AUDIO_DIAGNOSTICS=true` and compare `play.lookup_ready`, `play.source_load_ready` and `play.progress_started` from an uncached selection.

The optional lookup-only check `flutter test tool/startup_lookup_live_test.dart --dart-define=LIVE_LOOKUP=true` compares a cold lookup, a different song through the shared session, and a cached lookup. It does not measure native playback startup.

## Song-only discovery and stable seeking

Search uses the YouTube Music Songs filter, not general YouTube video search. Search and radio rows must identify their primary playback endpoint as `MUSIC_VIDEO_TYPE_ATV`; music videos, user videos, podcasts, playlists, unknown types and unavailable rows are rejected. An empty filtered response stays empty. Pagination retains the Songs filter. Radio requests audio-only recommendations and ignores video counterparts; artist fallback also uses song search. Your own library playlists still work as collections of individual songs.

Song classification is saved with track metadata. Older saved remote items are verified against music metadata before playback or download, including when audio is already cached. Confirmed legacy songs are marked in the library for future offline use; unverified old items require an online check first. Search and automatic recommendations exclude unverified old entries. Local audio imports remain available.

The timeline previews dragging locally and sends one seek on release. During source loading, buffering or a pending seek, controls show a loading circle and dragging is disabled. A pending seek holds its target through stale native position events until the seek finishes and the player reports a nearby position without buffering. Failures/timeouts restore the actual position, and changing tracks clears the old target.

The Music protocol is based on the current [ytmusicapi search filter](https://github.com/sigma67/ytmusicapi/blob/main/ytmusicapi/parsers/search.py) and [audio-only radio requests](https://github.com/sigma67/ytmusicapi/blob/main/ytmusicapi/mixins/watch.py). This public endpoint can change; failures remain failures rather than falling back to general video search.

Regressions: `music_songs_test.dart`, `playback_seek_test.dart`, `controller_test.dart`, and `repository_test.dart`. Public response fixtures in `test/fixtures/` retain only the fields needed for these cases. Live catalog checks cover actual song search, pagination, radio and audio bytes. Physical iOS checks should include dragging forward/backward, seeking while paused, buffering on a slow connection, track changes during a seek, and lock-screen seeking.

## Blend playlists

Choose **Blend playlists** in Your Library or on a playlist page. Name the blend, select at least two playlists, and tap **Create blend**. The picker previews the unique song count. Songs follow the displayed source order and their order within each playlist; the first occurrence of each song ID is kept. Originals are preserved. Blends are saved in one local library update, work offline, and can be played, edited, downloaded, or exported like other playlists. As on the web version, the maximum is 5,000 unique songs. Only music tracks and imported audio are included; older remote items need song verification before inclusion.

## Graphical equalizer

Settings now contains a five-band gain graph (60 Hz, 230 Hz, 910 Hz, 3.6 kHz and 14 kHz), draggable points, a precise gain slider, preset chips and an EQ on/off switch for comparison. Changes are sent to the playing source without pausing, seeking or downloading it again. Native filters smooth control changes over approximately 20 ms and reserve headroom when boosting frequencies. This changes tonal balance, not source bitrate or lost recording detail.

The waveform behind the graph comes from decoded PCM after the equalizer. It does not use the microphone or a synthetic animation. Only the visible panel polls it, at 20 updates per second, and polling stops when the panel closes or the app backgrounds. Flat EQ bypasses per-sample filters. Band settings are saved after a short pause in adjustment.

Android uses a Media3 PCM audio processor; iOS/macOS use an AVPlayer audio-mix processing tap. The app-owned `just_audio` patch is documented in `third_party/PATCHES.md`. `test/equalizer_test.dart` covers migration, saved bands, coalesced updates, no playback restart, failures, graph layout and polling cleanup. `tool/native/` includes signal tests for both filter implementations and a real AVFoundation audio-mix render test.

Song, downloaded-file and Replay sharing have been removed, along with `share_plus`. Library export saves a JSON file through the platform file picker rather than a share sheet.

These changes require a full native rebuild; hot reload/restart cannot add the processor or file-picker handlers. Run `flutter pub get`, `pod install` in `ios/` (or `macos/`) for Apple builds, then rebuild/reinstall with `flutter run`. Full native device builds require Android SDK/full Xcode and CocoaPods. A final listening check on Android/iPhone is needed for device-specific output routes and buffering.
