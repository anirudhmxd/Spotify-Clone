# Spotify Flutter app

The complete website interface reimplemented with native Flutter widgets and Dart. Includes Android, iOS, macOS, and web projects. The existing Python music API remains the shared server: it searches YouTube, resolves streams, downloads audio, and stores playlists and listening counts. No WebView or embedded copy of the website is used.

## Start the music server

From this folder, in a separate terminal:

```sh
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
python run_server.py
```

Stop the original website server first if it is already using port 5000. The wrapper reads the existing `../WEB-version/playlists.json` and `liked_songs.json`, so both versions share your library. FFmpeg is optional; install it to convert downloads to MP3. Without it, downloads use the source audio format.

## Run Flutter

Install the Flutter stable SDK, then from this folder:

```sh
flutter pub get
flutter run -d chrome --dart-define=API_BASE_URL=http://127.0.0.1:5000
```

For the desktop app on a Mac:

```sh
flutter run -d macos --dart-define=API_BASE_URL=http://127.0.0.1:5000
```

For the Android emulator:

```sh
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:5000
```

For the iOS simulator, use `http://127.0.0.1:5000`. For a physical phone, run `python run_server.py --host 0.0.0.0`, connect the phone and computer to the same Wi-Fi, and replace the server address with your computer's LAN IP. Native platform builds require the normal Android SDK or Xcode setup. Flutter does not bundle or start the Python server.

The local-development platform settings allow HTTP connections. Use an HTTPS server and remove broad cleartext allowances before public distribution. When serving the web build from an origin outside localhost, set `FLUTTER_ALLOWED_ORIGINS` to that exact origin when starting the API. The API has no authentication; keep it on your own machine or trusted network.

## Features

- Responsive sidebar on desktop; Search, For You, and Library tabs on phones.
- Debounced song/artist and YouTube playlist search, cancellation, stale-response protection, 20-second request timeout, and retryable pagination. Search never blocks the player or navigation.
- Streaming audio, persistent now-playing controls, previous/next, repeat, seeking, volume, and mute.
- Queue continuation with recommendations; each play is counted once after 85% of its duration.
- Create and delete playlists, add and remove songs, playlist artwork, duration totals, and play/pause playlist.
- Songs For You ranking, refresh controls, inline loading/errors, and snack-bar feedback.
- Download action opens the API download in the system browser. Files are saved through the browser's normal download flow.

## Checks and builds

```sh
flutter analyze
flutter test
flutter build web
flutter build apk
flutter build macos
# On a Mac with Xcode:
flutter build ios --no-codesign
```

The tests cover search races, clearing a pending search, pagination retry, recommendation queue continuation, listening counts, creating a playlist with a song, and responsive navigation while a search is pending.

Verified during conversion with Flutter 3.47.8: analyzer passed, all 9 tests passed, and the web release built successfully. Android, iOS, and macOS runners are included; native binaries have not been built or tested on devices. This machine has Xcode Command Line Tools rather than the full Xcode installation.

## Source layout

- `lib/main.dart`: app startup, theme, and server URL configuration.
- `lib/music_controller.dart`: search, library, queue, playback, and listening state.
- `lib/models/`: track and playlist models.
- `lib/services/`: HTTP API and audio player adapters.
- `lib/widgets/`: responsive screens, library, artwork, and player controls.
- `run_server.py`: shared API launcher with local Flutter web CORS support.

Audio uses [just_audio](https://pub.dev/packages/just_audio); HTTP uses [http](https://pub.dev/packages/http); external downloads use [url_launcher](https://pub.dev/packages/url_launcher).
