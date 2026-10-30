"""Rhythm's Python-only web backend. Run: python3 main.py (127.0.0.1:5001)."""
from __future__ import annotations
from concurrent.futures import ThreadPoolExecutor, TimeoutError
from datetime import date
import os
from pathlib import Path
import re
import threading
import time
import uuid
from urllib.parse import urlsplit

from flask import Flask, Response, abort, jsonify, redirect, request, send_file, send_from_directory, stream_with_context
from werkzeug.exceptions import HTTPException
from catalog import AUDIO_SUFFIXES, VIDEO_ID_RE, cached_search_entries, entry_to_track, open_audio, download_audio
from library import Library, sanitise_track, tracks

BASE_DIR = Path(__file__).resolve().parent


def create_app(data_dir=None):
    app = Flask(__name__,static_folder=None)
    app.config['MAX_CONTENT_LENGTH'] = 200 * 1024 * 1024
    directory=Path(data_dir or os.environ.get('RHYTHM_DATA_DIR',BASE_DIR))
    download_dir=directory/'downloads'
    library=Library(directory)
    app.extensions['library']=library
    search_pool=ThreadPoolExecutor(max_workers=3,thread_name_prefix='rhythm-search')
    search_slots=threading.BoundedSemaphore(3)
    download_pool=ThreadPoolExecutor(max_workers=2,thread_name_prefix='rhythm-download')
    jobs={}; job_lock=threading.Lock()
    app.extensions['executors']=[search_pool,download_pool]

    def payload():
        raw=request.get_json(silent=True)
        if not isinstance(raw,dict): raise ValueError('Expected a JSON object.')
        return raw

    def local_path(tid):
        from library import TRACK_ID
        if not TRACK_ID.fullmatch(tid): raise ValueError('Invalid song ID.')
        if not download_dir.exists(): return None
        return next((p for p in download_dir.glob(f'{tid}.*') if p.suffix.lower() in AUDIO_SUFFIXES and p.stat().st_size>0),None)

    def profile():
        d=library.read()
        downloads=[]
        for record in d['downloads'].values():
            path=local_path(record['track']['trackId'])
            if path: downloads.append(dict(track=record['track'],bytes=path.stat().st_size))
        songs=[dict(p['track'],fullPlays=p['count']) for p in sorted(d['plays'].values(),key=lambda p:p['count'],reverse=True)]
        return dict(settings=d['settings'],playlists=d['playlists'],liked=d['liked'],recent=d['recent'],
                    listening=list(d['listening'].values()),searches=d['searches'],downloads=downloads,songs=songs)

    @app.before_request
    def local_mutations():
        origin=request.headers.get('Origin')
        if request.method in ('POST','PATCH','PUT','DELETE') and origin:
            if urlsplit(origin).netloc != request.host: abort(403,description='Cross-origin changes are not allowed.')

    @app.errorhandler(ValueError)
    @app.errorhandler(TypeError)
    def bad_request(error): return jsonify(error=str(error)),400

    @app.errorhandler(LookupError)
    def missing(error): return jsonify(error=str(error)),404

    @app.errorhandler(HTTPException)
    def http_error(error): return jsonify(error=error.description),error.code

    @app.get('/')
    def index(): return send_from_directory(BASE_DIR,'index.html')

    @app.get('/<name>')
    def static_file(name):
        if name not in ['app.js','core.js','styles.css','manifest.webmanifest']: abort(404)
        return send_from_directory(BASE_DIR,name)

    @app.get('/assets/<path:name>')
    def asset(name): return send_from_directory(BASE_DIR/'assets',name)

    @app.get('/playlist.html')
    def old_playlist(): return redirect('/')

    @app.get('/api/profile')
    def api_profile(): return jsonify(profile())

    @app.route('/api/settings',methods=['PATCH','POST'])
    def settings(): return jsonify(settings=library.settings(payload()))

    @app.post('/api/search')
    def search():
        raw=payload(); query=str(raw.get('query','')).strip()[:250]
        page=int(raw.get('page',0))
        if not query or not 0 <= page <= 39: raise ValueError('Enter a query and a valid page.')
        d=library.read()
        if d['settings']['offline']:
            all_tracks=d['liked']+d['recent']+[r['track'] for r in d['downloads'].values()]+[t for p in d['playlists'] for t in p['tracks']]
            found={t['trackId']:t for t in all_tracks if query.casefold() in f"{t['trackName']} {t['artistName']}".casefold()}
            values=list(found.values()); result=values[page*25:(page+1)*25]; more=len(values)>(page+1)*25
        else:
            if not search_slots.acquire(blocking=False): return jsonify(error='Search is busy. Please retry shortly.'),429
            try:
                future=search_pool.submit(cached_search_entries,query,26,page*25)
            except Exception:
                search_slots.release(); raise
            future.add_done_callback(lambda _: search_slots.release())
            try: entries=future.result(timeout=18)
            except TimeoutError: return jsonify(error='Search took too long. Please try again.'),504
            except Exception: return jsonify(error='Search is unavailable. Check your connection and try again.'),502
            result=[entry_to_track(e) for e in entries[:25]]; more=len(entries)>25
        if page==0 and not d['settings']['privateSession'] and d['searches'][:1] != [query]:
            def remember(data): data['searches']=([query]+[s for s in data['searches'] if s!=query])[:12]
            library.change(remember)
        return jsonify(tracks=result,page=page,hasMore=more)

    @app.get('/api/playlists')
    def playlists(): return jsonify(playlists=library.read()['playlists'])

    @app.post('/api/playlists')
    def create_playlist(): return jsonify(playlist=library.create_playlist(payload())),201

    @app.post('/api/playlists/merge')
    def merge_playlists(): return jsonify(playlist=library.merge_playlists(payload())),201

    @app.patch('/api/playlists/<pid>')
    def edit_playlist(pid): return jsonify(playlist=library.edit_playlist(pid,payload()))

    @app.delete('/api/playlists/<pid>')
    def delete_playlist(pid):
        def remove(d):
            if not any(p['id']==pid for p in d['playlists']): raise LookupError('Playlist not found.')
            d['playlists']=[p for p in d['playlists'] if p['id']!=pid]
        library.change(remove); return jsonify(ok=True)

    @app.post('/api/playlists/<pid>/tracks')
    def add_track(pid):
        track=sanitise_track(payload().get('track'))
        def add(d):
            p=next((p for p in d['playlists'] if p['id']==pid),None)
            if p is None: raise LookupError('Playlist not found.')
            if not any(t['trackId']==track['trackId'] for t in p['tracks']): p['tracks'].append(track)
            return p
        return jsonify(playlist=library.change(add))

    @app.delete('/api/playlists/<pid>/tracks/<tid>')
    def remove_track(pid,tid):
        def remove(d):
            p=next((p for p in d['playlists'] if p['id']==pid),None)
            if p is None: raise LookupError('Playlist not found.')
            p['tracks']=[t for t in p['tracks'] if t['trackId']!=tid]
            return p
        return jsonify(playlist=library.change(remove))

    @app.post('/api/likes')
    def like():
        raw=payload(); track=sanitise_track(raw.get('track'))
        if not isinstance(raw.get('liked'),bool): raise ValueError('Invalid like state.')
        def update(d):
            d['liked']=[t for t in d['liked'] if t['trackId']!=track['trackId']]
            if raw['liked']: d['liked'].insert(0,track)
        library.change(update); return jsonify(ok=True)

    @app.post('/api/listening')
    def listening(): return jsonify(recorded=library.record(payload()))

    @app.delete('/api/history')
    def clear_history():
        def clear(d):
            d.update(plays={},recent=[],listening={},searches=[])
        library.change(clear); return jsonify(ok=True)

    @app.get('/api/liked-songs')
    def most_played(): return jsonify(songs=profile()['songs'][:20])

    @app.get('/api/liked-songs/recommend')
    def recommendations():
        exclude=set(request.args.getlist('exclude'))
        return jsonify(songs=[t for t in profile()['songs'] if t['trackId'] not in exclude][:15])

    @app.get('/api/library/export')
    def export_library():
        response=jsonify(library.export()); response.headers['Content-Disposition']='attachment; filename=rhythm-library.json'
        return response

    @app.post('/api/library/import')
    def import_library(): library.import_library(payload()); return jsonify(ok=True)

    @app.post('/api/import-audio')
    def import_audio():
        uploaded=request.files.get('file')
        suffix=Path(uploaded.filename or '').suffix.lower() if uploaded else ''
        if not uploaded or suffix not in AUDIO_SUFFIXES: raise ValueError('Choose an audio file (up to 200 MB).')
        tid='local_'+uuid.uuid4().hex; download_dir.mkdir(parents=True,exist_ok=True)
        path=download_dir/(tid+suffix); temp=path.with_suffix(suffix+'.part')
        try:
            uploaded.save(temp)
            if temp.stat().st_size==0: raise ValueError('The audio file is empty.')
            temp.replace(path)
            track=sanitise_track(dict(trackId=tid,trackName=Path(uploaded.filename).stem,artistName='Local files',collectionName='On this computer'))
            library.change(lambda d:d['downloads'].update({tid:dict(track=track)}))
        finally:
            if temp.exists(): temp.unlink()
        return jsonify(track=track),201

    @app.post('/api/downloads')
    def start_download():
        track=sanitise_track(payload().get('track')); tid=track['trackId']
        existing=local_path(tid)
        if existing:
            library.change(lambda d:d['downloads'].update({tid:dict(track=track)}))
            return jsonify(status='complete',track=track)
        if not VIDEO_ID_RE.fullmatch(tid): raise ValueError('This imported file is no longer available.')
        settings=library.read()['settings']
        if settings['offline']: raise ValueError('Turn off downloaded-only mode to download music.')
        with job_lock:
            if tid in jobs and jobs[tid]['status'] in ['queued','downloading']: return jsonify(jobs[tid]),202
            if sum(j['status'] in ['queued','downloading'] for j in jobs.values())>=20: return jsonify(error='The download queue is full. Please wait.'),429
            jobs[tid]=dict(id=tid,track=track,status='queued',error='')
        def work():
            with job_lock: jobs[tid]['status']='downloading'
            try:
                download_audio(tid,download_dir,settings['downloadQuality'])
                library.change(lambda d:d['downloads'].update({tid:dict(track=track)}))
                with job_lock: jobs[tid]['status']='complete'
            except Exception:
                with job_lock: jobs[tid].update(status='failed',error='Download failed. This track may be unavailable; try again.')
        download_pool.submit(work)
        return jsonify(id=tid,status='queued'),202

    @app.get('/api/downloads/jobs')
    def download_jobs():
        with job_lock: return jsonify(jobs=list(jobs.values()))

    @app.delete('/api/downloads/<tid>')
    def delete_download(tid):
        with job_lock:
            if jobs.get(tid,{}).get('status') in ['queued','downloading']: return jsonify(error='Wait for the download to finish.'),409
        path=local_path(tid)
        if path: path.unlink()
        library.change(lambda d:d['downloads'].pop(tid,None))
        return jsonify(ok=True)

    @app.get('/api/download/<tid>')
    def export_audio(tid):
        path=local_path(tid)
        if not path: raise LookupError('Save this song to downloads first.')
        name=re.sub(r'[\\/:*?"<>|\r\n\t]+','_',request.args.get('name',tid))[:120]
        return send_file(path,as_attachment=True,download_name=name+path.suffix,conditional=True)

    @app.get('/api/stream/<tid>')
    def stream(tid):
        path=local_path(tid)
        if path: return send_file(path,conditional=True)
        settings=library.read()['settings']
        if settings['offline']: return jsonify(error='This song is not downloaded.'),409
        if not VIDEO_ID_RE.fullmatch(tid): raise LookupError('The local file is no longer available.')
        try:
            source, upstream=open_audio(tid, settings['streamingQuality'], request.headers.get('Range'))
        except Exception: return jsonify(error='Audio is unavailable. Try another song.'),502
        if upstream.status_code == 416:
            total=upstream.headers.get('Content-Range', 'bytes */*')
            upstream.close()
            return Response(status=416, headers={'Content-Range':total, 'Accept-Ranges':'bytes'})
        if upstream.status_code not in (200,206):
            upstream.close(); return jsonify(error='The audio provider rejected this stream.'),502
        def chunks():
            try:
                yield from upstream.iter_content(32768)
            finally: upstream.close()
        response_headers={k:upstream.headers[k] for k in ['Content-Length','Content-Range','Content-Type','Content-Encoding'] if k in upstream.headers}
        response_headers.update({'Accept-Ranges':'bytes','Cache-Control':'no-store'})
        return Response(stream_with_context(chunks()),status=upstream.status_code,headers=response_headers)

    return app


app=create_app()
if __name__=='__main__':
    port=int(os.environ.get('PORT',5001))
    print(f'Rhythm is ready at http://127.0.0.1:{port}',flush=True)
    app.run(host='127.0.0.1',port=port,debug=False,threaded=True)
