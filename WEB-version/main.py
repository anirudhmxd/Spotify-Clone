"""
Local web server for the Spotify-style search and streaming UI.

Install:   pip install flask yt-dlp requests
Run:       python main.py
Open:      http://127.0.0.1:5000
"""

from __future__ import annotations

import json
import re
import threading
import time
import uuid
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
PLAYLISTS_FILE = BASE_DIR / "playlists.json"
LIKED_SONGS_FILE = BASE_DIR / "liked_songs.json"
LIKED_SONGS_THRESHOLD = 0.85   # 85 % of duration counts as "fully played"

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

# --- playlists ------------------------------------------------------------
_playlists_lock = threading.Lock()

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


def search_entries(query: str, limit: int = 25, offset: int = 0) -> list[dict]:
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
        max_results = limit + offset

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

    return kept[offset:max_results]


def cached_search_entries(query: str, limit: int = 25, offset: int = 0) -> list[dict]:
    global _search_cache

    key = f"{query.strip().lower()}|offset={offset}"
    now = time.time()

    with _search_lock:
        hit = _search_cache.get(key)
        if hit and hit[1] > now:
            return hit[0]

    entries = search_entries(query, limit, offset)

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


# --- playlist storage -----------------------------------------------------
def _read_playlists() -> list[dict]:
    try:
        with PLAYLISTS_FILE.open("r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return []
    if not isinstance(data, list):
        return []

    cleaned: list[dict] = []
    for item in data:
        if not isinstance(item, dict):
            continue
        pid = str(item.get("id") or "").strip()
        name = str(item.get("name") or "").strip()
        if not pid or not name:
            continue
        tracks = [
            t
            for t in (item.get("tracks") or [])
            if isinstance(t, dict) and VIDEO_ID_RE.match(str(t.get("trackId") or ""))
        ]
        cleaned.append(
            {
                "id": pid,
                "name": name,
                "createdAt": float(item.get("createdAt") or 0),
                "tracks": tracks,
            }
        )
    return cleaned


def _write_playlists(playlists: list[dict]) -> None:
    tmp = PLAYLISTS_FILE.with_name(PLAYLISTS_FILE.name + ".tmp")
    with tmp.open("w", encoding="utf-8") as fh:
        json.dump(playlists, fh, ensure_ascii=False, indent=2)
    tmp.replace(PLAYLISTS_FILE)


def _sanitise_track(raw: dict) -> dict | None:
    if not isinstance(raw, dict):
        return None
    vid = str(raw.get("trackId") or "")
    if not VIDEO_ID_RE.match(vid):
        return None

    def text(key: str, fallback: str, limit: int = 200) -> str:
        value = str(raw.get(key) or "").strip() or fallback
        return value[:limit]

    artwork = str(raw.get("artworkUrl100") or "").strip()
    if not artwork.startswith(("http://", "https://")):
        artwork = f"https://i.ytimg.com/vi/{vid}/mqdefault.jpg"

    try:
        millis = int(float(raw.get("trackTimeMillis") or 0))
    except (TypeError, ValueError):
        millis = 0

    return {
        "trackId": vid,
        "trackName": text("trackName", "Unknown title"),
        "artistName": text("artistName", "YouTube"),
        "collectionName": text("collectionName", "YouTube"),
        "trackTimeMillis": max(0, millis),
        "artworkUrl100": artwork[:500],
        "previewUrl": f"/api/stream/{vid}",
    }


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

    page = max(int(payload.get("page", 0)), 0)
    limit = 25
    offset = page * limit

    try:
        entries = cached_search_entries(query, limit, offset)
    except Exception as exc:  # noqa: BLE001
        return jsonify({"tracks": [], "error": f"Search failed: {exc}"}), 502

    return jsonify({"tracks": [entry_to_track(e) for e in entries], "page": page, "hasMore": len(entries) >= limit})


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


# --- liked-songs storage --------------------------------------------------
_liked_lock = threading.Lock()

def _read_liked_songs() -> dict[str, int]:
    try:
        with LIKED_SONGS_FILE.open("r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return {}
    if not isinstance(data, dict):
        return {}
    cleaned: dict[str, int] = {}
    for tid, count in data.items():
        if isinstance(tid, str) and VIDEO_ID_RE.match(tid) and isinstance(count, int) and count > 0:
            cleaned[tid] = count
    return cleaned

def _write_liked_songs(data: dict[str, int]) -> None:
    tmp = LIKED_SONGS_FILE.with_name(LIKED_SONGS_FILE.name + ".tmp")
    with tmp.open("w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
    tmp.replace(LIKED_SONGS_FILE)


# --- playlists API --------------------------------------------------------
@app.get("/api/playlists")
def api_list_playlists():
    with _playlists_lock:
        playlists = _read_playlists()
    return jsonify({"playlists": playlists})


@app.post("/api/playlists")
def api_create_playlist():
    payload = request.get_json(silent=True) or {}
    name = str(payload.get("name") or "").strip()
    if not name:
        return jsonify({"error": "Playlist name is required."}), 400

    playlist = {
        "id": uuid.uuid4().hex[:12],
        "name": name[:80],
        "createdAt": time.time(),
        "tracks": [],
    }

    with _playlists_lock:
        playlists = _read_playlists()
        playlists.append(playlist)
        _write_playlists(playlists)

    return jsonify({"playlist": playlist}), 201


@app.delete("/api/playlists/<playlist_id>")
def api_delete_playlist(playlist_id: str):
    with _playlists_lock:
        playlists = _read_playlists()
        remaining = [p for p in playlists if p["id"] != playlist_id]
        if len(remaining) == len(playlists):
            return jsonify({"error": "Playlist not found."}), 404
        _write_playlists(remaining)
    return jsonify({"ok": True})


@app.post("/api/playlists/<playlist_id>/tracks")
def api_add_playlist_track(playlist_id: str):
    payload = request.get_json(silent=True) or {}
    track = _sanitise_track(payload.get("track") or {})
    if track is None:
        return jsonify({"error": "Invalid track."}), 400

    with _playlists_lock:
        playlists = _read_playlists()
        playlist = next((p for p in playlists if p["id"] == playlist_id), None)
        if playlist is None:
            return jsonify({"error": "Playlist not found."}), 404

        duplicate = any(t["trackId"] == track["trackId"] for t in playlist["tracks"])
        if not duplicate:
            playlist["tracks"].append(track)
            _write_playlists(playlists)

    return jsonify({"playlist": playlist, "duplicate": duplicate})


@app.delete("/api/playlists/<playlist_id>/tracks/<track_id>")
def api_remove_playlist_track(playlist_id: str, track_id: str):
    if not VIDEO_ID_RE.match(track_id):
        abort(400)

    with _playlists_lock:
        playlists = _read_playlists()
        playlist = next((p for p in playlists if p["id"] == playlist_id), None)
        if playlist is None:
            return jsonify({"error": "Playlist not found."}), 404

        before = len(playlist["tracks"])
        playlist["tracks"] = [t for t in playlist["tracks"] if t["trackId"] != track_id]
        if len(playlist["tracks"]) == before:
            return jsonify({"error": "That song is not in the playlist."}), 404
        _write_playlists(playlists)

    return jsonify({"playlist": playlist})


# --- liked-songs API (Songs For You) --------------------------------------
@app.post("/api/liked-songs/score")
def api_score_liked_song():
    payload = request.get_json(silent=True) or {}
    track_id = str(payload.get("trackId") or "").strip()
    if not VIDEO_ID_RE.match(track_id):
        return jsonify({"error": "Invalid track ID."}), 400

    with _liked_lock:
        data = _read_liked_songs()
        data[track_id] = data.get(track_id, 0) + 1
        _write_liked_songs(data)

    return jsonify({"ok": True, "count": data[track_id]})


@app.get("/api/liked-songs")
def api_liked_songs():
    with _liked_lock:
        data = _read_liked_songs()

    if not data:
        return jsonify({"songs": []})

    # Resolve track metadata for the top songs (up to 20)
    sorted_ids = sorted(data, key=lambda tid: data[tid], reverse=True)[:20]
    songs = []
    for tid in sorted_ids:
        count = data[tid]
        try:
            entries = search_entries(tid, limit=1)
            if entries:
                track = entry_to_track(entries[0])
                track["fullPlays"] = count
                songs.append(track)
        except Exception:
            # If we can't resolve, skip it
            pass

    return jsonify({"songs": songs})


@app.get("/api/liked-songs/recommend")
def api_recommend():
    params = request.args
    exclude_ids = [str(t).strip() for t in params.getlist("exclude") if t.strip()]

    with _liked_lock:
        data = _read_liked_songs()

    if not data:
        return jsonify({"songs": []})

    # Exclude already-queued songs, then rank by full-play count
    available = {tid: cnt for tid, cnt in data.items() if tid not in exclude_ids}
    if not available:
        return jsonify({"songs": []})

    sorted_ids = sorted(available, key=lambda tid: available[tid], reverse=True)
    limit = int(params.get("limit", 10))
    songs = []
    for tid in sorted_ids[:limit]:
        try:
            entries = search_entries(tid, limit=1)
            if entries:
                track = entry_to_track(entries[0])
                track["fullPlays"] = available[tid]
                songs.append(track)
        except Exception:
            pass

    return jsonify({"songs": songs})


if __name__ == "__main__":
    print("Serving UI on http://127.0.0.1:8080")
    app.run(host="127.0.0.1", port=5000, debug=False, threaded=True)