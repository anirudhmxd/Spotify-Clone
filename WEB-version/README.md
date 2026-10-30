# Rhythm for the web

The Rhythm website uses a Python Flask backend and a build-free HTML/CSS/JavaScript browser interface. The browser handles its audio controls and visual effects; Python handles discovery, streaming, downloads, settings, and library storage. There is no Node.js backend and no remote server to configure.

## Start

Run these commands in `WEB-version` with Python 3.10 or later:

```sh
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
python main.py
```

Open **http://127.0.0.1:5001**. Keep this process running while using the website. If port 5001 is occupied, run `PORT=5002 python main.py` and use port 5002 instead. On Windows, activate the environment with `.venv\Scripts\activate`.

The server binds to this computer only. The standalone Flutter app in `../app version` still runs independently without a Python server. The two versions have separate libraries; library export/import transfers playlists and likes, while local audio must be imported separately.

## Included

- Rhythm logo, icons, dark violet/pink/blue theme, desktop sidebar, mobile navigation, and full-screen player dialog.
- Cached search shares overlapping requests for the same query and reuses equivalent text queries for five minutes. Debounced search with cancellation, stale-result protection, timeouts, retry, pagination, and YouTube playlist lookup. Navigation remains available during searches.
- Playback, seeking, volume, speed, shuffle, repeat, autoplay from library recommendations, queue editing, and sleep timers.
- Browser equalizer presets: flat, bass, vocals, and treble. Audio effects and media-key integration depend on browser support.
- Likes; playlist merging into a new collection with duplicate songs removed and originals preserved; playlist creation, renaming, descriptions, pinning, duplication, sorting and reordering; artist views; library filtering; JSON import/export.
- Background downloads, download progress, saved audio export, audio file import, and downloaded-only playback/search. Supported containers include MP3, M4A, MP4, WebM, Opus, Ogg, AAC, WAV, and FLAC; decoding depends on the browser.
- Listening history, full-listen rankings, private sessions, and yearly Rhythm Replay with real listening totals, top artists/songs, monthly activity, sharing, and a top-songs playlist.
- Saved profile name, playback preferences, quality choices, and history management.

Rhythm is an independent app using YouTube discovery, not Spotify's catalog or subscription service. Quality settings select the best available source; when only a combined MP4 stream exists, Rhythm plays its audio and saves the original container without requiring an external transcoder. That fallback can use more bandwidth than an audio-only file.

## Storage and offline use

Python saves `rhythm_library.json` and a recovery copy `rhythm_library.json.bak` beside the server, plus audio in `downloads/`. Existing `playlists.json` is imported on first use and left untouched. Legacy listen counts are carried over when their song metadata exists in those playlists. New likes are separate from listen counts.

Set `RHYTHM_DATA_DIR` to another directory to keep an isolated library. Back up that directory for complete recovery. The in-app JSON export includes playlists and likes, not audio, settings, or listening statistics. Imports merge collections and never trust file paths supplied in a backup.

Downloaded-only mode needs no internet for local audio, but the local Python process must remain running. This is not an offline service-worker application. Sleep timers use browser timers and may be delayed if the operating system suspends the browser. Private sessions exclude subsequent listening and searches from statistics.

## Verification and provider limits

```sh
python -m unittest discover -s tests -p 'test_*.py' -v
node --test tests/*.test.cjs
```

Node is optional and used only for browser-logic tests. It is not needed to run the website. The Python extractor explicitly disables external JavaScript runtimes.

Browser checks covered desktop/mobile layouts, local WAV playback, likes, creating a playlist with the selected song, Replay, and navigation during search. The playback cutoff was fixed by replacing the obsolete hard-coded source client with yt-dlp’s maintained Android client and preserving complete HTTP range responses. Source headers are retained, expired media URLs are refreshed once before sending bytes, and suffix seeks are converted to absolute offsets. Complete downloads of two songs, a complete web response, later-song byte comparisons, and end-of-song seeking passed live checks. In the browser, the 3:19 Blinding Lights lyrics track reached its end and automatically advanced to the next song without playback errors. All 26 automated tests passed. Incomplete downloads are discarded. Provider availability, regional restrictions, and future extractor changes can still affect individual tracks; local imported audio remains usable. Keep the Python dependencies updated when the provider changes its formats.

## Merge playlists

Choose **Merge playlists** in Your Library or on a playlist page. Enter a name, select at least two playlists, and choose **Create merged playlist**. Songs follow the displayed playlist order and retain their order within each source. The first occurrence of each song is kept. Originals remain available; merges above 5,000 unique songs are rejected without saving a partial playlist.
