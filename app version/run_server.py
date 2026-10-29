"""Run the shared music API for the Flutter app without changing the website."""
import argparse
import os
import runpy
from pathlib import Path
from urllib.parse import urlsplit

source = Path(__file__).resolve().parent.parent / 'WEB-version' / 'main.py'
app = runpy.run_path(str(source), run_name='spotify_shared_backend')['app']
allowed_origins = set(filter(None, os.environ.get('FLUTTER_ALLOWED_ORIGINS', '').split(',')))


@app.after_request
def flutter_cors(response):
    from flask import request
    origin = request.headers.get('Origin', '')
    parsed = urlsplit(origin)
    local = parsed.scheme == 'http' and parsed.hostname in ('localhost', '127.0.0.1', '::1')
    if local or origin in allowed_origins:
        response.headers['Access-Control-Allow-Origin'] = origin
        response.headers['Access-Control-Allow-Methods'] = 'GET, POST, DELETE, OPTIONS'
        response.headers['Access-Control-Allow-Headers'] = 'Content-Type, Range'
        response.headers['Access-Control-Expose-Headers'] = 'Content-Length, Content-Range, Accept-Ranges'
        response.vary.add('Origin')
    return response


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--port', type=int, default=5000)
    args = parser.parse_args()
    app.run(host=args.host, port=args.port, debug=False, threaded=True)
