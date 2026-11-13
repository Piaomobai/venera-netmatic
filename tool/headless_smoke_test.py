#!/usr/bin/env python3
"""Exercise a compiled desktop CLI against an isolated profile and loopback DAV.
No real source, account or NAS is used. Run with --executable and --profile-root.
"""
import argparse
import base64
import hashlib
import http.server
import json
import pathlib
import signal
import sqlite3
import subprocess
import tempfile
import threading
import time
import urllib.parse
from xml.sax.saxutils import escape

PNG = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jN1sAAAAASUVORK5CYII=')
SOURCE = r'''
class Fixture extends ComicSource {
  name = "CLI Fixture";
  key = "fixture";
  version = "1.0.0";
  minAppVersion = "1.0.0";
  explore = [];
  url = "http://127.0.0.1:PORT/source.js";
  async init() { await new Promise(resolve => setTimeout(resolve, 30)); this.ready = true; }
  search = { load: async (query, options, page) => {
    if (!this.ready) throw "not initialized";
    return {comics: [{id: "book", title: query, cover: "http://127.0.0.1:PORT/image.png", tags: [], description: "fixture"}], maxPage: 3};
  }};
  comic = {
    loadInfo: async (id) => {
      if (!this.ready) throw "not initialized";
      if (id === "missing") throw "not found";
      return {title: "Fixture book", subTitle: "Fixture author", cover: "http://127.0.0.1:PORT/image.png",
        description: "local fixture", tags: {author: ["Fixture author"]}, chapters: {one: "One"}};
    },
    loadEp: async (id, ep) => ({images: ["http://127.0.0.1:PORT/image.png?1", "http://127.0.0.1:PORT/image.png?2"]})
  };
}
'''

class Dav(http.server.BaseHTTPRequestHandler):
    files = {}
    dirs = {'/'}
    fail_backup = False
    image_delay = 0
    lock = threading.RLock()

    def log_message(self, *_):
        pass

    def path_key(self, raw=None):
        return urllib.parse.unquote(urllib.parse.urlsplit(raw or self.path).path).rstrip('/') or '/'

    def reply(self, status, data=b'', headers=None):
        self.send_response(status)
        self.send_header('Content-Length', str(len(data)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(data)

    def do_GET(self):
        key = self.path_key()
        if key == '/image.png':
            time.sleep(self.image_delay)
            return self.reply(200, PNG, {'Content-Type': 'image/png'})
        with self.lock:
            data = self.files.get(key)
        self.reply(404 if data is None else 200, data or b'')

    def do_HEAD(self):
        self.do_GET()

    def do_OPTIONS(self):
        self.reply(200, headers={'DAV': '1, 2',
            'Allow': 'OPTIONS, GET, HEAD, PUT, DELETE, MKCOL, PROPFIND, MOVE'})

    def do_MKCOL(self):
        with self.lock:
            key = self.path_key()
            existing = key in self.dirs
            self.dirs.add(key)
        self.reply(405 if existing else 201)

    def do_PUT(self):
        data = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        key = self.path_key()
        if self.fail_backup and key.endswith('.venera'):
            return self.reply(503)
        with self.lock:
            self.files[key] = data
        self.reply(201)

    def do_DELETE(self):
        key = self.path_key()
        with self.lock:
            for item in list(self.files):
                if item == key or item.startswith(key + '/'):
                    del self.files[item]
            self.dirs.discard(key)
        self.reply(204)

    def do_MOVE(self):
        key, target = self.path_key(), self.path_key(self.headers['Destination'])
        with self.lock:
            if key not in self.files:
                return self.reply(404)
            self.files[target] = self.files.pop(key)
        self.reply(201)

    def do_PROPFIND(self):
        self.rfile.read(int(self.headers.get('Content-Length', '0')))
        key = self.path_key()
        with self.lock:
            if key not in self.dirs and key not in self.files:
                return self.reply(404)
            paths = [key]
            if self.headers.get('Depth') != '0':
                prefix = '' if key == '/' else key
                paths += sorted(p for p in self.dirs | self.files.keys()
                                if p != key and p.startswith(prefix + '/')
                                and '/' not in p[len(prefix) + 1:])
            responses = []
            for item in paths:
                directory = item in self.dirs
                href = urllib.parse.quote(item + ('/' if directory and item != '/' else ''))
                data = self.files.get(item, b'')
                resource = '<d:collection/>' if directory else ''
                responses.append(f'''<d:response><d:href>{escape(href)}</d:href><d:propstat><d:prop>
<d:resourcetype>{resource}</d:resourcetype><d:getcontentlength>{len(data)}</d:getcontentlength>
<d:getlastmodified>Mon, 02 Nov 2026 00:00:00 GMT</d:getlastmodified>
<d:getetag>"{hashlib.md5(data).hexdigest()}"</d:getetag>
</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>''')
        body = ('<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">' + ''.join(responses) + '</d:multistatus>').encode()
        self.reply(207, body, {'Content-Type': 'application/xml; charset=utf-8'})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--executable', required=True)
    parser.add_argument('--profile-root', required=True)
    options = parser.parse_args()
    executable = str(pathlib.Path(options.executable).resolve())
    root = pathlib.Path(options.profile_root)
    root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='venera-cli-smoke-', dir=root) as scratch:
        scratch = pathlib.Path(scratch)
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Dav)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        port = server.server_port
        passed = []

        def profile(name):
            path = scratch / name
            (path / 'comic_source').mkdir(parents=True)
            (path / 'comic_source' / 'fixture.js').write_text(SOURCE.replace('PORT', str(port)))
            settings = {'webdav': [f'http://127.0.0.1:{port}', 'fixture', 'fixture-password'],
                'nasConnections': [{'id': 'nas', 'name': 'Fixture NAS', 'protocol': 'webdav',
                    'host': f'http://127.0.0.1:{port}', 'username': 'fixture', 'password': 'fixture-password',
                    'remotePath': 'Venera'}]}
            (path / 'appdata.json').write_text(json.dumps({'settings': settings, 'searchHistory': []}))
            return path

        first, second = profile('first'), profile('second')

        def argv(path, *args):
            return [executable, '--headless', '--json', '--data-dir', str(path), *args]

        def decode(stdout):
            # Every stdout line must be JSON, including in debug mode.
            values = [json.loads(line) for line in stdout.splitlines() if line]
            assert values, 'No CLI result'
            return values

        def run(path, *args, code=0):
            result = subprocess.run(argv(path, *args), capture_output=True, text=True, timeout=45)
            values = decode(result.stdout)
            assert result.returncode == code, (args, result.returncode, values[-1], result.stderr[-1500:])
            return values[-1]

        try:
            assert run(first, 'help')['status'] == 'success'
            assert run(first, 'library', 'list', '--queue-timeout', '1', code=2)['code'] == 'invalid_arguments'
            sources = run(first, 'sources', 'list')['data']
            assert sources['sources'], sources
            assert run(first, 'search', 'fixture', '中文', '--page', '2')['data']['maxPage'] == 3
            assert run(first, 'comic', 'chapters', 'fixture', 'book')['data']['chapters'] == {'one': 'One'}
            assert run(first, 'comic', 'get', 'fixture', 'missing', code=1)['code'] == 'source_error'
            passed.append('JSON protocol, source initialization, search, details and errors')
            listing = run(first, 'nas', 'list')
            assert 'fixture-password' not in json.dumps(listing)
            passed.append('NAS connection redaction')
            queued = run(first, 'downloads', 'add', 'fixture', 'book', '--enqueue-only')
            job = queued['data']['jobId']
            assert queued['status'] == 'queued'
            assert run(first, 'jobs', 'get', job)['data']['state'] == 'queued'
            assert len(run(first, 'downloads', 'list')['data']['tasks']) == 1
            assert run(first, 'downloads', 'run')['data']['completed'] == 1
            assert run(first, 'jobs', 'get', job)['data']['state'] == 'completed'
            assert run(first, 'library', 'list')['data']['total'] == 1
            assert run(second, 'library', 'list')['data']['total'] == 0
            assert not run(first, 'downloads', 'list')['data']['tasks']
            passed.append('Durable queue, resumed download, final completion and profile isolation')
            run(first, 'nas', 'test', 'nas')
            run(first, 'nas', 'upload', 'nas')
            assert run(second, 'nas', 'library', 'nas')['data']['total'] == 1
            run(second, 'nas', 'download', 'nas', 'fixture', 'book')
            assert run(second, 'library', 'list')['data']['total'] == 1
            passed.append('NAS upload, index query, checksum validation and download')
            source_path = first / 'comic_source' / 'fixture.js'
            source_path.write_text(source_path.read_text().replace(
                'chapters: {one: "One"}', 'chapters: {one: "One", two: "Two"}'))
            incremental = run(first, 'scheduler', 'create', 'incrementalDownload',
                '--schedule', '{"type":"interval","intervalSeconds":3600}',
                '--config', '{"scope":"library","nasConnectionId":"nas"}')['data']['id']
            result = run(first, 'scheduler', 'run', incremental)
            assert result['data']['failed'] == 0
            assert set(run(first, 'library', 'list')['data']['items'][0]['downloadedChapters']) == {'one', 'two'}
            assert set(run(second, 'nas', 'library', 'nas')['data']['items'][0]['downloadedChapters']) == {'one', 'two'}
            run(first, 'scheduler', 'delete', incremental)
            passed.append('Scheduled incremental download waits for local commit and NAS upload')
            run(first, 'webdav', 'up')
            Dav.fail_backup = True
            assert run(first, 'webdav', 'up', code=1)['status'] == 'error'
            Dav.fail_backup = False
            run(first, 'webdav', 'up')
            configuration = profile('configuration')
            run(configuration, 'webdav', 'down')
            assert run(configuration, 'sources', 'list')['data']['sources']
            passed.append('WebDAV upload, import, source reload and failed upload exit code')
            ids = []
            for name in ['one', 'two']:
                result = run(first, 'scheduler', 'create', 'nasSync', '--name', name,
                    '--schedule', '{"type":"interval","intervalSeconds":3600}', '--config', '{"nasConnectionId":"nas"}')
                ids.append(result['data']['id'])
            with sqlite3.connect(first / 'scheduler.db') as database:
                database.execute('UPDATE scheduled_tasks SET next_run_at = 1')
            result = run(first, 'scheduler', 'rundue')
            assert result['data']['executed'] == 2
            assert result['data']['failed'] == 0
            assert len(run(first, 'scheduler', 'history', ids[0])['data']['runs']) == 1
            run(first, 'scheduler', 'disable', ids[0])
            run(first, 'scheduler', 'enable', ids[0])
            run(first, 'scheduler', 'update', ids[0], '--name', 'renamed')
            passed.append('Scheduler CRUD, due batch and persisted history')
            # Keep stdout unbuffered when mixing readline() and communicate().
            # TextIOWrapper may prefetch subsequent JSON lines, which
            # communicate() then bypasses while reading the pipe directly.
            daemon = subprocess.Popen(argv(first, 'scheduler', 'serve'), stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, bufsize=0)
            try:
                ready = json.loads(daemon.stdout.readline())
                assert ready['data']['state'] == 'ready'
                assert run(first, 'library', 'list', code=3)['code'] == 'app_busy'
                daemon.send_signal(signal.SIGTERM)
                stdout, _ = daemon.communicate(timeout=15)
                assert decode(stdout.decode())[-1]['code'] == 'cancelled'
                assert daemon.returncode == 130
            finally:
                if daemon.poll() is None:
                    daemon.kill()
                    daemon.wait()
            assert run(first, 'library', 'list')['status'] == 'success'
            passed.append('Concurrent process exclusion, daemon cancellation and lock release')
            # Cancel during a real delayed image request, then resume the saved queue.
            third = profile('cancel-download')
            run(third, 'downloads', 'add', 'fixture', 'book', '--enqueue-only')
            Dav.image_delay = 1.5
            transfer = subprocess.Popen(argv(third, 'downloads', 'run'), stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, bufsize=0)
            try:
                progress = json.loads(transfer.stdout.readline())
                assert progress['status'] == 'running'
                transfer.send_signal(signal.SIGTERM)
                stdout, _ = transfer.communicate(timeout=15)
                assert decode(stdout.decode())[-1]['code'] == 'cancelled'
                assert transfer.returncode == 130
            finally:
                Dav.image_delay = 0
                if transfer.poll() is None:
                    transfer.kill()
                    transfer.wait()
            assert run(third, 'downloads', 'list')['data']['tasks']
            assert run(third, 'downloads', 'run')['data']['completed'] == 1
            passed.append('Real in-flight download cancellation, settled writes and resumed completion')
            print(json.dumps({'passed': len(passed), 'checks': passed}, ensure_ascii=False, indent=2))
        finally:
            server.shutdown()
            server.server_close()


if __name__ == '__main__':
    main()
