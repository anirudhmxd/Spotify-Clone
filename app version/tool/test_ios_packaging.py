"""Exercise the iOS packaging script using fixture files (no Xcode/signing)."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

APP = Path(__file__).resolve().parents[1]
SCRIPT = APP / 'third_party/ytdlp_flutter/ios/scripts/install_python_stdlib.sh'

class PackagingTest(unittest.TestCase):
    def test_device_and_simulator_packaging(self):
        for platform, slice_name, arch, tag in [
            ('-iphoneos', 'ios-arm64', 'arm64', 'arm64-iphoneos'),
            ('-iphonesimulator', 'ios-arm64_x86_64-simulator', 'arm64', 'arm64-iphonesimulator'),
            ('-iphonesimulator', 'ios-arm64_x86_64-simulator', 'x86_64', 'x86_64-iphonesimulator'),
        ]:
            with self.subTest(platform=platform, arch=arch), tempfile.TemporaryDirectory(prefix='rhythm packaging ') as tmp:
                root = Path(tmp)
                plugin = root / 'plugin/ios'
                framework = plugin / 'Python.xcframework'
                files = {
                    framework / 'lib/python3.13/encodings/__init__.py': '# encodings',
                    framework / 'lib/python3.13/test/excluded.py': '# test',
                    framework / f'{slice_name}/lib-{arch}/python3.13/lib-dynload/_ssl.cpython-313.so': 'fixture binary',
                    framework / f'{slice_name}/platform-config/{tag}/_sysconfigdata__ios.py': '# config',
                    plugin / 'Resources/yt-dlp.pyz': 'fixture zip',
                    plugin / 'Resources/cacert.pem': 'fixture cert',
                    plugin.parent / 'python/worker.py': '# current worker',
                }
                for path, content in files.items():
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text(content)
                app = root / 'Runner.app'
                env = dict(os.environ, YTDLP_FLUTTER_IOS_DIR=str(plugin), ARCHS=arch,
                           EFFECTIVE_PLATFORM_NAME=platform, CODESIGNING_FOLDER_PATH=str(app),
                           PRODUCT_BUNDLE_IDENTIFIER='com.example.rhythm', EXPANDED_CODE_SIGN_IDENTITY='')
                for _ in range(2):  # incremental builds must work too
                    result = subprocess.run(['/bin/sh', str(SCRIPT)], env=env, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertTrue((app / 'python-stdlib/encodings/__init__.py').exists())
                    self.assertTrue((app / 'Frameworks/_ssl.framework/_ssl').exists())
                    self.assertFalse(list((app / 'python-stdlib').rglob('*.so')))
                    self.assertFalse((app / 'python-stdlib/test').exists())
                    self.assertEqual((app / 'worker.py').read_text(), '# current worker')
                    self.assertEqual((app / 'python-stdlib/lib-dynload/_ssl.cpython-313.fwork').read_text().strip(), 'Frameworks/_ssl.framework/_ssl')
                (plugin / 'Resources/yt-dlp.pyz').unlink()
                result = subprocess.run(['/bin/sh', str(SCRIPT)], env=env, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Missing Python runtime input', result.stdout)

if __name__ == '__main__':
    unittest.main()
