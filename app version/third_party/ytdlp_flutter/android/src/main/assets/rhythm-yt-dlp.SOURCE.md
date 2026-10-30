# Bundled Android extractor

Official yt-dlp standalone Python zipapp, distributed under the Unlicense.

- Version: 2026.10.26
- Source/release: https://github.com/yt-dlp/yt-dlp/releases/tag/2026.10.26
- Asset: https://github.com/yt-dlp/yt-dlp/releases/download/2026.10.26/yt-dlp
- SHA-256: e51e69e89489f199530f13d32a4342da3ddb2cf34842f364603a066db05afbf3
- Upstream license: https://github.com/yt-dlp/yt-dlp/blob/2026.10.26/LICENSE

The app-owned BundledExtractor verifies this digest before atomically replacing
an older installed extractor. Newer runtime updates are preserved. This asset
avoids a mandatory on-device network update during the first song.

To upgrade, replace the asset from an official release, verify its release digest,
and update VERSION/SHA256 in BundledExtractor.kt together. Run the native fixture
checks and the app test suite. The Android wrapper stays at the latest published
Maven version, 0.18.1; its bundled extractor is independent and older.
