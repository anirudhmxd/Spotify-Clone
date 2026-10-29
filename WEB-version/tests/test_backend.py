import io
import json
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch, MagicMock
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from main import create_app
from library import Library

SONG=dict(trackId='aaaaaaaaaaa',trackName='A <song>',artistName='Artist',trackTimeMillis=100000)
OTHER=dict(trackId='bbbbbbbbbbb',trackName='Second',artistName='Other')

class BackendTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        self.app=create_app(self.root);self.app.testing=True;self.client=self.app.test_client()
    def tearDown(self):
        for pool in self.app.extensions['executors']:pool.shutdown(wait=True)
        self.temp.cleanup()
    def post(self,url,body):return self.client.post(url,json=body)
    def profile(self):return self.client.get('/api/profile').get_json()

    def test_existing_playlists_migrate_without_changing_original(self):
        original=[dict(id='old',name='Existing',tracks=[SONG],createdAt=1)]
        path=self.root/'playlists.json';path.write_text(json.dumps(original))
        self.assertEqual(self.profile()['playlists'][0]['name'],'Existing')
        self.client.patch('/api/settings',json={'displayName':'Rhythm listener'})
        self.assertEqual(json.loads(path.read_text()),original)
        self.assertEqual(Library(self.root).read()['settings']['displayName'],'Rhythm listener')

    def test_playlist_create_with_song_edit_pin_sort_duplicate_and_delete(self):
        r=self.post('/api/playlists',{'name':'New','tracks':[SONG]});self.assertEqual(r.status_code,201)
        p=r.get_json()['playlist'];self.assertEqual(len(p['tracks']),1)
        self.post(f"/api/playlists/{p['id']}/tracks",{'track':SONG})
        r=self.client.patch('/api/playlists/'+p['id'],json={'name':'Edited','description':'Notes','pinned':True,'tracks':[OTHER,SONG]})
        self.assertEqual(r.get_json()['playlist']['tracks'][0]['trackId'],OTHER['trackId'])
        self.assertTrue(self.profile()['playlists'][0]['pinned'])
        self.client.delete('/api/playlists/'+p['id']);self.assertEqual(self.profile()['playlists'],[])

    def test_settings_validation_likes_and_backup_recovery(self):
        self.assertEqual(self.client.patch('/api/settings',json={'speed':99}).status_code,400)
        self.assertEqual(self.client.patch('/api/settings',json={'volume':float('nan')}).status_code,400)
        self.client.patch('/api/settings',json={'speed':1.5,'privateSession':True,'equalizer':'bass'})
        self.post('/api/likes',{'track':SONG,'liked':True});self.post('/api/likes',{'track':SONG,'liked':True})
        self.assertEqual(len(self.profile()['liked']),1)
        (self.root/'rhythm_library.json').write_text('{broken')
        self.assertEqual(self.profile()['settings']['speed'],1.5)
        self.post('/api/likes',{'track':SONG,'liked':False});self.assertEqual(self.profile()['liked'],[])

    def test_listening_idempotent_private_and_clear_keeps_library(self):
        event=dict(track=SONG,milliseconds=15000,newPlay=True,fullPlay=True,day='2026-10-29',eventId='event-1')
        self.post('/api/listening',event);self.post('/api/listening',event)
        p=self.profile();self.assertEqual(p['listening'][0]['milliseconds'],15000);self.assertEqual(p['songs'][0]['fullPlays'],1)
        self.client.patch('/api/settings',json={'privateSession':True});event['eventId']='event-2';self.post('/api/listening',event)
        self.assertEqual(self.profile()['listening'][0]['plays'],1)
        self.post('/api/likes',{'track':SONG,'liked':True});self.client.delete('/api/history');p=self.profile()
        self.assertEqual(p['listening'],[]);self.assertEqual(p['songs'],[]);self.assertEqual(len(p['liked']),1)

    def test_local_import_range_playback_and_download_only_mode(self):
        data=b'RIFF'+b'\x00'*1000
        r=self.client.post('/api/import-audio',data={'file':(io.BytesIO(data),'My song.wav')},content_type='multipart/form-data')
        self.assertEqual(r.status_code,201);track=r.get_json()['track'];self.assertEqual(track['trackName'],'My song')
        self.client.patch('/api/settings',json={'offline':True})
        with patch('main.open_audio',side_effect=AssertionError('No network allowed')):
            response=self.client.get(track['previewUrl'],headers={'Range':'bytes=0-3'})
            self.assertEqual(response.status_code,206);self.assertEqual(response.data,b'RIFF');response.close()
            self.assertEqual(self.client.get('/api/stream/aaaaaaaaaaa').status_code,409)
        found=self.post('/api/search',{'query':'My song','page':0}).get_json()['tracks'];self.assertEqual(len(found),1)
        self.assertEqual(self.post('/api/downloads',{'track':SONG}).status_code,400)
        self.client.delete('/api/downloads/'+track['trackId']);self.assertEqual(self.profile()['downloads'],[])

    def test_import_validation_and_export_never_trust_local_paths(self):
        body=dict(version=1,playlists=[dict(name='Imported',tracks=[SONG,dict(trackId='local_abc',previewUrl='file:///etc/passwd')])],liked=[OTHER])
        self.assertEqual(self.post('/api/library/import',body).status_code,200)
        p=self.profile();self.assertEqual(len(p['playlists'][0]['tracks']),1);self.assertEqual(len(p['liked']),1)
        exported=self.client.get('/api/library/export').get_json();self.assertEqual(exported['version'],1)
        self.assertEqual(self.post('/api/library/import',dict(version=1,playlists=[{'name':''}])).status_code,400)
        self.assertEqual(len(self.profile()['playlists']),1)

    def test_background_download_dedup_and_profile_responsiveness(self):
        started=threading.Event();finish=threading.Event();calls=[]
        def fake(tid,directory,quality):
            calls.append(tid);started.set();finish.wait(2);directory.mkdir(exist_ok=True);p=directory/(tid+'.m4a');p.write_bytes(b'audio');return p
        with patch('main.download_audio',side_effect=fake):
            r=self.post('/api/downloads',{'track':SONG});self.assertEqual(r.status_code,202);started.wait(1)
            self.post('/api/downloads',{'track':SONG});self.assertEqual(len(calls),1)
            self.assertEqual(self.client.get('/api/profile').status_code,200)
            self.assertEqual(self.client.delete('/api/downloads/aaaaaaaaaaa').status_code,409)
            finish.set()
            for _ in range(100):
                if self.client.get('/api/downloads/jobs').get_json()['jobs'][0]['status']=='complete':break
                time.sleep(.01)
            self.assertEqual(len(self.profile()['downloads']),1)

    def test_search_pagination_validation_and_no_global_blocking(self):
        entries=[dict(id=f'{n:011d}',title=f'Song {n}') for n in range(26)]
        with patch('main.cached_search_entries',return_value=entries) as search:
            r=self.post('/api/search',{'query':'Music','page':2});self.assertEqual(r.status_code,200)
            self.assertEqual(len(r.get_json()['tracks']),25);self.assertTrue(r.get_json()['hasMore']);search.assert_called_once_with('Music',26,50)
        self.assertEqual(self.post('/api/search',{'query':'x','page':'invalid'}).status_code,400)
        self.assertEqual(self.post('/api/search',{'query':'x','page':-1}).status_code,400)

    def test_online_stream_delivers_beyond_first_megabyte_and_preserves_seek(self):
        data = b'a' * (2 * 1048576 + 123)
        upstream = MagicMock(status_code=200)
        upstream.headers = {'Content-Length': str(len(data)), 'Content-Type': 'video/mp4'}
        upstream.iter_content.return_value = iter([data[:1048576], data[1048576:]])
        with patch('main.open_audio', return_value=({}, upstream)) as source:
            response = self.client.get('/api/stream/aaaaaaaaaaa')
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.data, data)
            source.assert_called_once_with('aaaaaaaaaaa', 'high', None)
            response.close()
            upstream.close.assert_called_once()
        upstream = MagicMock(status_code=206)
        upstream.headers = {'Content-Range': f'bytes 1048576-{len(data)-1}/{len(data)}',
                            'Content-Length': str(len(data)-1048576), 'Content-Type': 'video/mp4'}
        upstream.iter_content.return_value = iter([data[1048576:]])
        with patch('main.open_audio', return_value=({}, upstream)) as source:
            response = self.client.get('/api/stream/aaaaaaaaaaa', headers={'Range':'bytes=1048576-'})
            self.assertEqual(response.status_code, 206)
            self.assertEqual(response.data, data[1048576:])
            self.assertEqual(response.headers['Content-Range'], upstream.headers['Content-Range'])
            source.assert_called_once_with('aaaaaaaaaaa', 'high', 'bytes=1048576-')
            response.close()

    def test_unsatisfiable_online_seek_preserves_416(self):
        upstream = MagicMock(status_code=416)
        upstream.headers = {'Content-Range': 'bytes */4000'}
        with patch('main.open_audio', return_value=({}, upstream)):
            response = self.client.get('/api/stream/aaaaaaaaaaa', headers={'Range':'bytes=9999-'})
            self.assertEqual(response.status_code, 416)
            self.assertEqual(response.headers['Content-Range'], 'bytes */4000')
            upstream.close.assert_called_once()

    def test_untrusted_paths_and_cross_origin_mutations_rejected(self):
        self.assertEqual(self.client.get('/assets/../main.py').status_code,404)
        self.assertEqual(self.post('/api/likes',{'track':{'trackId':'../../etc/passwd'},'liked':True}).status_code,400)
        r=self.client.post('/api/playlists',json={'name':'Injected'},headers={'Origin':'https://unrelated.example'})
        self.assertEqual(r.status_code,403)
        self.assertEqual(self.client.post('/api/import-audio',data={'file':(io.BytesIO(b'bad'),'script.py')}).status_code,400)

if __name__=='__main__':unittest.main()
