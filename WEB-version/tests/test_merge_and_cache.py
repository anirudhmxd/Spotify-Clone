import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from library import Library
from main import create_app
import catalog

class MergeTests(unittest.TestCase):
    def test_merge_preserves_sources_and_order(self):
        with tempfile.TemporaryDirectory() as directory:
            lib = Library(directory)
            a = dict(trackId='aaaaaaaaaaa', trackName='First')
            b = dict(trackId='bbbbbbbbbbb', trackName='Second')
            first = lib.create_playlist(dict(name='First', tracks=[a]))
            second = lib.create_playlist(dict(name='Second', tracks=[b, a]))
            merged = lib.merge_playlists(dict(name='Together', playlistIds=[second['id'], first['id']]))
            self.assertEqual([t['trackId'] for t in merged['tracks']], [b['trackId'], a['trackId']])
            saved = Library(directory).read()['playlists']
            self.assertEqual(saved, [first, second, merged])
            for ids in [[first['id']], [first['id'], first['id']], [first['id'], 'missing']]:
                with self.assertRaises((ValueError, LookupError)):
                    lib.merge_playlists(dict(name='Invalid', playlistIds=ids))
            self.assertEqual(lib.read()['playlists'], saved)

    def test_endpoint_and_empty_playlists(self):
        with tempfile.TemporaryDirectory() as directory:
            app = create_app(directory)
            try:
                client = app.test_client()
                ids = [client.post('/api/playlists', json={'name': n}).get_json()['playlist']['id'] for n in ['A', 'B']]
                result = client.post('/api/playlists/merge', json={'name': 'Both', 'playlistIds': ids})
                self.assertEqual(result.status_code, 201)
                self.assertEqual(result.get_json()['playlist']['tracks'], [])
                self.assertEqual(client.post('/api/playlists/merge', json={'name': 'Bad', 'playlistIds': ids[:1]}).status_code, 400)
            finally:
                for pool in app.extensions['executors']: pool.shutdown(wait=True)

class CacheTests(unittest.TestCase):
    def setUp(self):
        catalog._search_cache.clear()
        catalog._search_pending.clear()

    def test_normalized_hits_expiration_and_retry(self):
        with patch('catalog.search_entries', side_effect=[RuntimeError('offline'), [], [{'id': 'bbbbbbbbbbb'}]]) as search:
            with self.assertRaises(RuntimeError): catalog.cached_search_entries('song')
            self.assertEqual(catalog.cached_search_entries('song'), [])
            self.assertEqual(catalog.cached_search_entries(' SONG '), [])
            catalog._search_cache[('song', 25, 0)] = ([], 0)
            self.assertEqual(catalog.cached_search_entries('song'), [{'id': 'bbbbbbbbbbb'}])
            self.assertEqual(search.call_count, 3)

    def test_concurrent_searches_share_pending_work(self):
        from concurrent.futures import ThreadPoolExecutor
        import threading
        entered, release = threading.Event(), threading.Event()
        def provider(*args):
            entered.set()
            self.assertTrue(release.wait(3))
            return []
        with patch('catalog.search_entries', side_effect=provider) as search, ThreadPoolExecutor(2) as pool:
            first = pool.submit(catalog.cached_search_entries, 'My Song')
            self.assertTrue(entered.wait(3))
            second = pool.submit(catalog.cached_search_entries, 'my song')
            release.set()
            self.assertEqual(first.result(), second.result())
            self.assertEqual(search.call_count, 1)
