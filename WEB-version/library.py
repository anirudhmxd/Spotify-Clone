"""Atomic Python-owned library, with non-destructive migration of the old website."""
from __future__ import annotations
from copy import deepcopy
from datetime import date
import json
import math
from pathlib import Path
import re
import threading
import time
import uuid

TRACK_ID = re.compile(r'^(?:[A-Za-z0-9_-]{11}|local_[a-f0-9]+)$')
DEFAULT_SETTINGS = dict(displayName='Your music', autoplay=True, offline=False,
    privateSession=False, speed=1, volume=.7, equalizer='flat',
    streamingQuality='high', downloadQuality='high')


def sanitise_track(raw, allow_local=True):
    if not isinstance(raw, dict): raise ValueError('Invalid song.')
    tid = str(raw.get('trackId') or raw.get('id') or '')
    if not TRACK_ID.fullmatch(tid) or (not allow_local and tid.startswith('local_')):
        raise ValueError('Invalid song ID.')
    def text(key, alias, fallback): return str(raw.get(key) or raw.get(alias) or fallback).strip()[:250]
    try: duration = max(0, min(int(raw.get('trackTimeMillis', raw.get('durationMs', 0)) or 0), 86400000))
    except (ValueError, TypeError, OverflowError): duration = 0
    art = str(raw.get('artworkUrl100') or raw.get('artwork') or '')
    if not art.startswith(('https://', 'http://')): art = '/assets/rhythm-icon.png'
    return dict(trackId=tid, trackName=text('trackName','title','Unknown title'),
        artistName=text('artistName','artist','Local files' if tid.startswith('local_') else 'YouTube'),
        collectionName=text('collectionName','album','Your music'), trackTimeMillis=duration,
        artworkUrl100=art[:1000], previewUrl=f'/api/stream/{tid}')


def tracks(raw, allow_local=True):
    if not isinstance(raw, list): raise ValueError('Songs must be a list.')
    found = {}
    for item in raw[:5000]:
        try:
            t = sanitise_track(item, allow_local)
            found[t['trackId']] = t
        except ValueError: continue
    return list(found.values())


def validate_settings(raw, previous):
    if not isinstance(raw, dict): raise ValueError('Invalid settings.')
    result = dict(previous)
    for key in ['autoplay', 'offline', 'privateSession']:
        if key in raw:
            if not isinstance(raw[key], bool): raise ValueError(f'Invalid {key}.')
            result[key] = raw[key]
    for key, low, high in [('speed', .5, 2), ('volume', 0, 1)]:
        if key in raw:
            value = float(raw[key])
            if not math.isfinite(value) or not low <= value <= high: raise ValueError(f'Invalid {key}.')
            result[key] = value
    for key in ['streamingQuality','downloadQuality']:
        if key in raw:
            if raw[key] not in ['dataSaver','balanced','high']: raise ValueError('Invalid quality.')
            result[key] = raw[key]
    if 'equalizer' in raw:
        if raw['equalizer'] not in ['flat','bass','vocal','treble']: raise ValueError('Invalid equalizer.')
        result['equalizer'] = raw['equalizer']
    if 'displayName' in raw:
        result['displayName'] = str(raw['displayName']).strip()[:50] or 'Your music'
    return result


class Library:
    def __init__(self, directory):
        self.directory = Path(directory)
        self.path = self.directory / 'rhythm_library.json'
        self.lock = threading.RLock()

    def _read(self):
        if not self.path.exists() and not self.path.with_suffix('.json.bak').exists():
            data = dict(version=1, settings=dict(DEFAULT_SETTINGS), playlists=[], liked=[],
                        plays={}, recent=[], listening={}, searches=[], downloads={}, events=[])
            legacy = self.directory / 'playlists.json'
            if legacy.exists():
                saved = json.loads(legacy.read_text())
                if not isinstance(saved, list): raise ValueError('The existing playlist file is invalid; it has been preserved.')
                for p in saved:
                    if isinstance(p, dict) and p.get('id') and p.get('name'):
                        data['playlists'].append(dict(id=str(p['id']), name=str(p['name'])[:80],
                            description=str(p.get('description',''))[:500], pinned=bool(p.get('pinned',False)),
                            createdAt=p.get('createdAt',0), tracks=tracks(p.get('tracks',[]))))
            old_scores = self.directory / 'liked_songs.json'
            if old_scores.exists():
                counts = json.loads(old_scores.read_text())
                known = {t['trackId']:t for p in data['playlists'] for t in p['tracks']}
                for tid, count in counts.items():
                    if tid in known and isinstance(count,int) and count > 0:
                        data['plays'][tid] = dict(track=known[tid], count=count)
            return data
        for path in [self.path, self.path.with_suffix('.json.bak')]:
            try:
                data = json.loads(path.read_text())
                if not isinstance(data,dict) or data.get('version') != 1: raise ValueError('Invalid library version.')
                return data
            except (OSError, ValueError): continue
        raise ValueError('The saved library cannot be read. Its files have been preserved.')

    def _write(self, data):
        self.directory.mkdir(parents=True,exist_ok=True)
        content = json.dumps(data,ensure_ascii=False)
        for dest in [self.path, self.path.with_suffix('.json.bak')]:
            temp = dest.with_name(dest.name+'.tmp')
            with temp.open('w') as file:
                file.write(content); file.flush()
                import os
                os.fsync(file.fileno())
            temp.replace(dest)

    def read(self):
        with self.lock: return deepcopy(self._read())

    def change(self, fn):
        with self.lock:
            data = self._read()
            result = fn(data)
            self._write(data)
            return deepcopy(result)

    def settings(self, value):
        def update(d):
            d['settings'] = validate_settings(value,d['settings'])
            return d['settings']
        return self.change(update)

    def playlist(self, pid):
        return next((p for p in self.read()['playlists'] if p['id']==pid),None)

    def create_playlist(self, raw):
        name = str(raw.get('name','')).strip()[:80]
        if not name: raise ValueError('Playlist name is required.')
        p = dict(id=uuid.uuid4().hex,name=name,description=str(raw.get('description',''))[:500],
                 pinned=False,createdAt=time.time(),tracks=tracks(raw.get('tracks',[])))
        return self.change(lambda d: (d['playlists'].append(p), p)[1])

    def edit_playlist(self, pid, raw):
        def update(d):
            p = next((p for p in d['playlists'] if p['id']==pid),None)
            if p is None: raise LookupError('Playlist not found.')
            if 'name' in raw:
                name = str(raw['name']).strip()[:80]
                if not name: raise ValueError('Playlist name is required.')
                p['name'] = name
            if 'description' in raw: p['description'] = str(raw['description'])[:500]
            if 'pinned' in raw: p['pinned'] = bool(raw['pinned'])
            if 'tracks' in raw: p['tracks'] = tracks(raw['tracks'])
            return p
        return self.change(update)

    def record(self, raw):
        track = sanitise_track(raw.get('track'))
        ms = int(raw.get('milliseconds',0))
        if not 0 < ms <= 60000: raise ValueError('Invalid listening duration.')
        day = date.fromisoformat(raw.get('day','')).isoformat()
        event = str(raw.get('eventId',''))
        if not re.fullmatch(r'[a-zA-Z0-9_-]{1,100}',event): raise ValueError('Invalid listening event.')
        def update(d):
            if d['settings']['privateSession'] or event in d['events']: return False
            d['events'] = (d['events']+[event])[-2000:]
            key = f"{day}|{track['trackId']}"
            entry = d['listening'].setdefault(key,dict(track=track,day=day,milliseconds=0,plays=0))
            entry['milliseconds'] += ms
            entry['plays'] += 1 if raw.get('newPlay') is True else 0
            d['recent'] = [track]+[t for t in d['recent'] if t['trackId']!=track['trackId']][:99]
            if raw.get('fullPlay') is True:
                p = d['plays'].setdefault(track['trackId'],dict(track=track,count=0)); p['count']+=1
            return True
        return self.change(update)

    def export(self):
        d=self.read()
        return dict(version=1,playlists=d['playlists'],liked=d['liked'])

    def import_library(self, raw):
        if not isinstance(raw,dict) or raw.get('version')!=1 or not isinstance(raw.get('playlists'),list):
            raise ValueError('Not a Rhythm library export.')
        # Validate completely before modifying the saved library.
        imported=[]
        for item in raw['playlists'][:500]:
            if not isinstance(item,dict) or not str(item.get('name','')).strip(): raise ValueError('Invalid playlist in backup.')
            imported.append(dict(id=uuid.uuid4().hex,name=str(item['name'])[:80],description=str(item.get('description',''))[:500],
                pinned=False,createdAt=time.time(),tracks=tracks(item.get('tracks',[]),allow_local=False)))
        liked=tracks(raw.get('liked',[]),allow_local=False)
        def update(d):
            d['playlists'].extend(imported)
            d['liked']=list({t['trackId']:t for t in d['liked']+liked}.values())
        self.change(update)
