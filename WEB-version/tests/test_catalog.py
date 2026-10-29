import sys
from pathlib import Path
import unittest
import tempfile
from unittest.mock import patch, MagicMock
import yt_dlp

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from catalog import audio_format, YDL_BASE, download_audio, open_audio


class FormatSelectionTests(unittest.TestCase):
    def select(self, quality, formats):
        with yt_dlp.YoutubeDL(YDL_BASE) as ydl:
            selector = ydl.build_format_selector(audio_format(quality))
            return list(selector({'formats': formats, 'has_merged_format': False,
                                  'incomplete_formats': False}))

    def test_mp4_fallback_plays_audio_when_audio_only_is_missing(self):
        video = dict(format_id='18', ext='mp4', acodec='mp4a.40.2',
                     vcodec='avc1', url='https://example.com/video.mp4')
        for quality in ['dataSaver', 'balanced', 'high']:
            self.assertEqual(self.select(quality, [video])[0]['format_id'], '18')

    def test_audio_only_is_preferred_and_silent_video_is_rejected(self):
        video = dict(format_id='18', ext='mp4', acodec='mp4a.40.2',
                     vcodec='avc1', url='https://example.com/video.mp4')
        audio = dict(format_id='140', ext='m4a', acodec='mp4a.40.2', abr=128,
                     vcodec='none', url='https://example.com/audio.m4a')
        self.assertEqual(self.select('high', [video, audio])[0]['format_id'], '140')
        self.assertEqual(self.select('high', [{**video, 'acodec': 'none'}]), [])


class DownloadIntegrityTests(unittest.TestCase):
    def test_complete_download_and_incomplete_files_never_published(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            response = MagicMock()
            response.__enter__.return_value = response
            response.status_code = 200
            response.headers = {'Content-Length': '4'}
            response.iter_content.return_value = iter([b'ab', b'cd'])
            source = dict(url='https://example.googlevideo.com/audio', ext='mp4', size=4)
            with patch('catalog.open_audio', return_value=(source, response)):
                result = download_audio('aaaaaaaaaaa', root)
                self.assertEqual(result.read_bytes(), b'abcd')
                response.iter_content.return_value = iter([b'ab'])
                with self.assertRaisesRegex(RuntimeError, 'incomplete'):
                    download_audio('bbbbbbbbbbb', root)
                self.assertFalse((root/'bbbbbbbbbbb.mp4').exists())
                self.assertFalse((root/'bbbbbbbbbbb.mp4.part').exists())


class SourceRetryTests(unittest.TestCase):
    def test_expired_url_is_refreshed_and_range_and_source_headers_survive(self):
        source = dict(url='https://example.googlevideo.com/audio', headers={'User-Agent':'source-client'})
        rejected, accepted = MagicMock(status_code=403), MagicMock(status_code=206)
        with patch('catalog.resolve_audio', return_value=source) as resolve, patch('catalog.requests.get', side_effect=[rejected, accepted]) as get:
            _, response = open_audio('aaaaaaaaaaa', 'high', 'bytes=1048576-')
            self.assertIs(response, accepted)
            rejected.close.assert_called_once()
            self.assertEqual([c.kwargs['refresh'] for c in resolve.call_args_list], [False, True])
            self.assertEqual(get.call_args.kwargs['headers']['Range'], 'bytes=1048576-')
            self.assertEqual(get.call_args.kwargs['headers']['User-Agent'], 'source-client')

    def test_full_request_does_not_invent_a_partial_range(self):
        source = dict(url='https://example.googlevideo.com/audio', headers={})
        with patch('catalog.resolve_audio', return_value=source), patch('catalog.requests.get', return_value=MagicMock(status_code=200)) as get:
            open_audio('aaaaaaaaaaa')
            self.assertNotIn('Range', get.call_args.kwargs['headers'])

    def test_suffix_range_uses_absolute_offsets_when_source_size_is_unknown(self):
        source = dict(url='https://example.googlevideo.com/audio', headers={}, size=0)
        probe = MagicMock(status_code=206)
        probe.__enter__.return_value = probe
        probe.headers = {'Content-Range':'bytes 0-0/9000'}
        accepted = MagicMock(status_code=206)
        with patch('catalog.resolve_audio', return_value=source), patch('catalog.requests.get', side_effect=[probe, accepted]) as get:
            open_audio('aaaaaaaaaaa', 'high', 'bytes=-1024')
            self.assertEqual(get.call_args.kwargs['headers']['Range'], 'bytes=7976-8999')
