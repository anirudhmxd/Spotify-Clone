"""
Local web server for the Spotify-style search and streaming UI.

Install:   pip install flask yt-dlp requests
Run:       python main.py
Open:      http://127.0.0.1:5000
"""

from __future__ import annotations

import re
import threading
import time
from pathlib import Path

import requests
import yt_dlp
from flask import (
    Flask,
    Response,
    abort,
    jsonify,
    redirect,
    request,
    send_file,
    send_from_directory,
    stream_with_context,
)

BASE_DIR = Path(__file__).resolve().parent
DOWNLOAD_DIR = BASE_DIR / "downloads"
DOWNLOAD_DIR.mkdir(exist_ok=True)

app = Flask(__name__, static_folder=None)

VIDEO_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")
AUDIO_SUFFIXES = {".mp3", ".m4a", ".webm", ".opus", ".ogg", ".aac", ".wav"}

PLAYLIST_URL_RE = re.compile(
    r"^(?:https?://)?(?:www\.|music\.)?(?:youtube\.com|youtu\.be)/"
    r".*(?:\blist=|\/playlist\/)",
    re.IGNORECASE,
)

PLAYLIST_MAX = 100   # how many tracks to expose from a playlist

YDL_BASE = {
    "quiet": True,
    "no_warnings": True,
    "noplaylist": True,
    "nocheckcertificate": True,
}

# --- caches ---------------------------------------------------------------
_stream_lock = threading.Lock()
_stream_cache: dict[str, tuple[str, float]] = {}
_download_locks: dict[str, threading.Lock] = {}
STREAM_TTL = 25 * 60

_search_lock = threading.Lock()
_search_cache: dict[str, tuple[list[dict], float]] = {}
SEARCH_TTL = 5 * 60
SEARCH_CACHE_MAX = 200

# --- music filtering ------------------------------------------------------
MIN_DURATION = 30
MAX_DURATION = 15 * 60
BAD_TITLE_KEYWORDS = (
    "full album",
    "full concert",
    "live stream",
    "podcast",
    "interview",
    "audiobook",
    "reaction",
    "tutorial",
    "how to",
)


def is_playlist_url(query: str) -> bool:
    return bool(PLAYLIST_URL_RE.search(query.strip()))


def is_music_entry(entry: dict) -> bool:
    duration = _parse_duration(entry)
    if duration and (duration < MIN_DURATION or duration > MAX_DURATION):
        return False
    title = (entry.get("track") or entry.get("title") or "").lower()
    if any(keyword in title for keyword in BAD_TITLE_KEYWORDS):
        return False
    return True


def _parse_duration(entry: dict) -> float:
    d = entry.get("duration")
    if isinstance(d, (int, float)) and d > 0:
        return float(d)
    ds = entry.get("duration_string") or entry.get("lengthText") or ""
    if isinstance(ds, str) and ":" in ds:
        try:
            secs = 0
            for part in ds.split(":"):
                secs = secs * 60 + int(part)
            return float(secs)
        except ValueError:
            pass
    return 0.0


def music_score(entry: dict) -> int:
    title = (entry.get("title") or "").lower()
    channel = (entry.get("channel") or entry.get("uploader") or "").lower()
    score = 0
    if channel.endswith(" - topic"):
        score += 4
    if "vevo" in channel:
        score += 3
    if "lyric" in title:
        score += 2
    if "audio" in title:
        score += 2
    if "official" in title:
        score += 1
    if "video" in title:
        score -= 2
    if "live" in title:
        score -= 1
    if "cover" in title:
        score -= 1
    return score


# --- yt-dlp helpers -------------------------------------------------------
def _base_search_opts() -> dict:
    return dict(
        YDL_BASE,
        extract_flat=True,
        skip_download=True,
        socket_timeout=8,
        ignoreerrors=True,
        no_color=True,
        cachedir=False,
        retries=1,
        extractor_retries=1,
    )


def search_entries(query: str, limit: int = 25) -> list[dict]:
    is_playlist = is_playlist_url(query)

    if is_playlist:
        opts = _base_search_opts()
        opts["noplaylist"] = False          # allow playlist extraction
        opts["playlistend"] = PLAYLIST_MAX
        target_url = query.strip()
        max_results = PLAYLIST_MAX
    else:
        opts = _base_search_opts()
        fetch_n = min(max(limit * 2, 30), 50)
        target_url = f"ytsearch{fetch_n}:{query}"
        max_results = limit

    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(target_url, download=False) or {}

    raw = info.get("entries") or []

    seen = set()
    kept = []
    for entry in raw:
        if not entry:
            continue
        vid = str(entry.get("id") or "")
        if not VIDEO_ID_RE.match(vid) or vid in seen:
            continue
        # Only filter search results, not user-supplied playlists.
        if not is_playlist and not is_music_entry(entry):
            continue
        seen.add(vid)
        kept.append(entry)

    if not is_playlist:
        kept.sort(key=music_score, reverse=True)

    return kept[:max_results]


def cached_search_entries(query: str, limit: int = 25) -> list[dict]:
    global _search_cache

    key = query.strip().lower()
    now = time.time()

    with _search_lock:
        hit = _search_cache.get(key)
        if hit and hit[1] > now:
            return hit[0]

    entries = search_entries(query, limit)

    with _search_lock:
        if len(_search_cache) >= SEARCH_CACHE_MAX:
            _search_cache = {k: v for k, v in _search_cache.items() if v[1] > now}
        _search_cache[key] = (entries, now + SEARCH_TTL)

    return entries


def entry_to_track(entry: dict) -> dict:
    vid = entry["id"]

    track_name = entry.get("track") or entry.get("title") or "Unknown title"
    artist_name = (
        entry.get("artist")
        or entry.get("channel")
        or entry.get("uploader")
        or "YouTube"
    )
    album_name = entry.get("album") or "YouTube"

    thumbs = entry.get("thumbnails") or []
    artwork = next(
        (t.get("url") for t in thumbs if "mqdefault" in (t.get("url") or "")), None
    )
    if not artwork:
        artwork = f"https://i.ytimg.com/vi/{vid}/mqdefault.jpg"

    duration = _parse_duration(entry)
    return {
        "trackId": vid,
        "trackName": track_name,
        "artistName": artist_name,
        "collectionName": album_name,
        "trackTimeMillis": int(duration * 1000),
        "artworkUrl100": artwork,
        "previewUrl": f"/api/stream/{vid}",
    }


def resolve_stream_url(video_id: str) -> str:
    now = time.time()
    with _stream_lock:
        cached = _stream_cache.get(video_id)
        if cached and cached[1] > now:
            return cached[0]

    opts = dict(YDL_BASE, format="bestaudio[ext=m4a]/bestaudio/best", socket_timeout=15)
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(f"https://www.youtube.com/watch?v={video_id}", download=False)

    url = info.get("url")
    if not url:
        raise RuntimeError("no audio stream available")

    with _stream_lock:
        _stream_cache[video_id] = (url, now + STREAM_TTL)
    return url


def download_audio(video_id: str) -> Path:
    lock = _download_locks.setdefault(video_id, threading.Lock())
    with lock:
        for candidate in sorted(DOWNLOAD_DIR.glob(f"{video_id}.*")):
            if candidate.suffix.lower() in AUDIO_SUFFIXES:
                return candidate

        page = f"https://www.youtube.com/watch?v={video_id}"
        outtmpl = str(DOWNLOAD_DIR / "%(id)s.%(ext)s")
        base_opts = dict(YDL_BASE, outtmpl=outtmpl, format="bestaudio/best")

        try:
            opts = dict(
                base_opts,
                postprocessors=[
                    {
                        "key": "FFmpegExtractAudio",
                        "preferredcodec": "mp3",
                        "preferredquality": "192",
                    }
                ],
            )
            with yt_dlp.YoutubeDL(opts) as ydl:
                ydl.extract_info(page, download=True)
        except Exception:
            with yt_dlp.YoutubeDL(base_opts) as ydl:
                ydl.extract_info(page, download=True)

        for candidate in sorted(DOWNLOAD_DIR.glob(f"{video_id}.*")):
            if candidate.suffix.lower() in AUDIO_SUFFIXES:
                return candidate

        raise RuntimeError("download produced no audio file")


# --- static files ---------------------------------------------------------
@app.get("/")
def index():
    return send_from_directory(str(BASE_DIR), "index.html")


@app.get("/app.js")
def app_js():
    return send_from_directory(str(BASE_DIR), "app.js", mimetype="application/javascript")


@app.get("/playlist.html")
def retired_playlist_page():
    return redirect("/")


@app.get("/styles.css")
def styles_css():
    return send_from_directory(str(BASE_DIR), "styles.css", mimetype="text/css")


# --- API ------------------------------------------------------------------
@app.post("/api/search")
def api_search():
    payload = request.get_json(silent=True) or {}
    query = (payload.get("query") or "").strip()
    if not query:
        return jsonify({"tracks": [], "error": "Enter a song, artist, or playlist URL."}), 400

    try:
        entries = cached_search_entries(query, 25)
    except Exception as exc:  # noqa: BLE001
        return jsonify({"tracks": [], "error": f"Search failed: {exc}"}), 502

    return jsonify({"tracks": [entry_to_track(e) for e in entries]})


@app.get("/api/stream/<video_id>")
def api_stream(video_id: str):
    if not VIDEO_ID_RE.match(video_id):
        abort(400)

    try:
        upstream_url = resolve_stream_url(video_id)
    except Exception as exc:  # noqa: BLE001
        return jsonify({"error": f"Could not resolve stream: {exc}"}), 502

    headers = {}
    range_header = request.headers.get("Range")
    if range_header:
        headers["Range"] = range_header

    try:
        upstream = requests.get(upstream_url, headers=headers, stream=True, timeout=30)
    except requests.RequestException as exc:
        return jsonify({"error": f"Stream unavailable: {exc}"}), 502

    if upstream.status_code not in (200, 206):
        upstream.close()
        return jsonify({"error": "Stream unavailable."}), 502

    def generate():
        try:
            for chunk in upstream.iter_content(chunk_size=32 * 1024):
                if chunk:
                    yield chunk
        finally:
            upstream.close()

    resp_headers = {
        "Content-Type": upstream.headers.get("Content-Type", "audio/mp4"),
        "Accept-Ranges": "bytes",
        "Cache-Control": "no-store",
    }
    for key in ("Content-Length", "Content-Range"):
        if key in upstream.headers:
            resp_headers[key] = upstream.headers[key]

    return Response(
        stream_with_context(generate()),
        status=upstream.status_code,
        headers=resp_headers,
    )


@app.get("/api/download/<video_id>")
def api_download(video_id: str):
    if not VIDEO_ID_RE.match(video_id):
        abort(400)

    try:
        path = download_audio(video_id)
    except Exception as exc:  # noqa: BLE001
        return jsonify({"error": f"Download failed: {exc}"}), 502

    requested = request.args.get("name") or path.stem
    safe = re.sub(r'[\\/:*?"<>|\r\n\t]+', "_", requested).strip() or path.stem
    safe = safe[:120]

    return send_file(
        path,
        as_attachment=True,
        download_name=f"{safe}{path.suffix}",
        mimetype="audio/mpeg" if path.suffix == ".mp3" else None,
    )


if __name__ == "__main__":
    print("Serving UI on http://127.0.0.1:5000")
    app.run(host="127.0.0.1", port=5000, debug=False, threaded=True)
