"""Python-only YouTube catalog and audio extraction for Rhythm."""
from __future__ import annotations
import re
import threading
import time
from pathlib import Path
import yt_dlp
import requests
from urllib.parse import urlparse

VIDEO_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")
AUDIO_SUFFIXES = {'.mp3', '.m4a', '.mp4', '.webm', '.opus', '.ogg', '.aac', '.wav', '.flac'}
YDL_BASE = {'quiet': True, 'no_warnings': True, 'noplaylist': True, 'cachedir': False,
            'socket_timeout': 10, 'retries': 1, 'extractor_retries': 1, 'js_runtimes': {}}
PLAYLIST_URL_RE = re.compile(r'^(?:https?://)?(?:www\.|music\.)?(?:youtube\.com|youtu\.be)/.*(?:\blist=|/playlist/)', re.I)
_stream_lock = threading.Lock()
_stream_cache = {}
_search_lock = threading.Lock()
_search_cache = {}
STREAM_TTL = 1200
SEARCH_TTL = 300
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


def search_entries(query: str, limit: int = 25, offset: int = 0) -> list[dict]:
    is_playlist = is_playlist_url(query)

    if is_playlist:
        opts = _base_search_opts()
        opts["noplaylist"] = False          # allow playlist extraction
        opts["playliststart"] = offset + 1
        opts["playlistend"] = offset + limit
        target_url = query.strip()
        max_results = limit
    else:
        opts = _base_search_opts()
        fetch_n = min(max((limit + offset) * 2, 30), 1000)
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

    return kept[:limit] if is_playlist else kept[offset:max_results]


def cached_search_entries(query: str, limit: int = 25, offset: int = 0) -> list[dict]:
    global _search_cache

    key = f"{query.strip()}|offset={offset}|limit={limit}"
    now = time.time()

    with _search_lock:
        hit = _search_cache.get(key)
        if hit and hit[1] > now:
            return hit[0]

    entries = search_entries(query, limit, offset)

    with _search_lock:
        if len(_search_cache) >= SEARCH_CACHE_MAX:
            _search_cache = {k: v for k, v in _search_cache.items() if v[1] > now}
        if len(_search_cache) >= SEARCH_CACHE_MAX:
            _search_cache.pop(next(iter(_search_cache)))
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


def audio_format(quality: str) -> str:
    if quality == 'dataSaver':
        return 'worstaudio[ext=m4a]/worstaudio/worst[ext=mp4][acodec!=none]'
    if quality == 'balanced':
        return 'bestaudio[ext=m4a][abr<=128]/bestaudio[ext=m4a]/bestaudio/best[ext=mp4][acodec!=none]'
    return 'bestaudio[ext=m4a]/bestaudio/best[ext=mp4][acodec!=none]'


def resolve_audio(video_id: str, quality: str = 'high', *, refresh: bool = False) -> dict:
    """Use yt-dlp's maintained client configuration, including its media headers."""
    if not VIDEO_ID_RE.fullmatch(video_id):
        raise ValueError('Invalid song ID.')
    key = (video_id, quality)
    now = time.time()
    with _stream_lock:
        cached = _stream_cache.get(key)
        if not refresh and cached and cached[1] > now:
            return dict(cached[0])
    opts = dict(YDL_BASE, format=audio_format(quality),
                extractor_args={'youtube': {'player_client': ['android']}})
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(f'https://www.youtube.com/watch?v={video_id}', download=False) or {}
    url = info.get('url', '')
    if urlparse(url).scheme != 'https' or not (urlparse(url).hostname or '').endswith('.googlevideo.com'):
        raise RuntimeError('No compatible audio is available for this song.')
    source = dict(url=url, ext=info.get('ext', 'm4a'), size=info.get('filesize') or 0,
                  headers=dict(info.get('http_headers') or {}))
    with _stream_lock:
        if len(_stream_cache) >= 200: _stream_cache.pop(next(iter(_stream_cache)))
        _stream_cache[key] = (source, now + STREAM_TTL)
    return dict(source)


def open_audio(video_id: str, quality: str = 'high', byte_range: str | None = None):
    """Open the complete requested range; retry an expired URL before sending bytes."""
    for attempt in range(2):
        source = resolve_audio(video_id, quality, refresh=bool(attempt))
        headers = {**source.get('headers', {}), 'Accept-Encoding': 'identity'}
        if byte_range is not None:
            # Google media servers require absolute offsets for suffix ranges.
            suffix = re.fullmatch(r'bytes=-(\d+)', byte_range)
            if suffix and int(suffix[1]) > 0:
                size = source.get('size') or 0
                if not size:
                    with requests.get(source['url'], headers={**headers, 'Range':'bytes=0-0'},
                                      stream=True, timeout=(10, 25)) as probe:
                        total = re.fullmatch(r'bytes \d+-\d+/(\d+)', probe.headers.get('Content-Range', ''))
                        if total: size = int(total[1])
                if size:
                    headers['Range'] = f'bytes={max(0, size-int(suffix[1]))}-{size-1}'
                else:
                    headers['Range'] = byte_range
            else:
                headers['Range'] = byte_range
        response = requests.get(source['url'], headers=headers, stream=True, timeout=(10, 25))
        if response.status_code in (401, 403, 410) and attempt == 0:
            response.close()
            continue
        return source, response
    raise RuntimeError('Audio is unavailable.')


def download_audio(video_id: str, directory: Path, quality: str = 'high') -> Path:
    if not VIDEO_ID_RE.fullmatch(video_id): raise ValueError('Invalid song ID.')
    directory.mkdir(parents=True, exist_ok=True)
    for candidate in directory.glob(f'{video_id}.*'):
        if candidate.suffix in AUDIO_SUFFIXES and candidate.stat().st_size > 0:
            return candidate
    source, response = open_audio(video_id, quality)
    suffix = '.' + source['ext']
    if suffix not in AUDIO_SUFFIXES:
        response.close()
        raise RuntimeError('Unsupported audio container.')
    destination = directory / (video_id + suffix)
    temporary = destination.with_suffix(suffix + '.part')
    deadline = time.monotonic() + 600
    try:
        with response:
            response.raise_for_status()
            if response.status_code != 200:
                raise RuntimeError('The provider did not return a complete audio file.')
            expected = source.get('size') or int(response.headers.get('Content-Length') or 0)
            written = 0
            with temporary.open('wb') as output:
                for chunk in response.iter_content(65536):
                    if time.monotonic() > deadline:
                        raise RuntimeError('Download timed out. Please retry.')
                    if chunk:
                        output.write(chunk)
                        written += len(chunk)
            if not written or (expected and written != expected):
                raise RuntimeError('The download was incomplete. Please retry.')
        temporary.replace(destination)
        return destination
    finally:
        temporary.unlink(missing_ok=True)
