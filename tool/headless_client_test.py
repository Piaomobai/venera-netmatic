"""Regression tests for submit-once polling and reconnection."""
import fcntl
import http.server
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parent.parent


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, data):
        body = json.dumps({'ok': True, 'data': data}).encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        self.rfile.read(int(self.headers['Content-Length']))
        self.server.submissions += 1
        self.reply({'id': 'request-one'})

    def do_GET(self):
        if self.server.finish_after:
            self.server.finish_after -= 1
            if not self.server.finish_after:
                self.server.finished = True
        self.reply({'state': 'completed' if self.server.finished else 'running',
                    'exitCode': 0, 'result': {'data': {}}})


class ClientTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.token = self.root / 'token'
        self.token.write_text('fixture-token')
        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.server.submissions = 0
        self.server.finish_after = 0
        self.server.finished = False
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temp.cleanup()

    def run_client(self, *args):
        return subprocess.run([
            sys.executable, '-B', str(ROOT / 'docker/headless_client.py'),
            '--url', f'http://127.0.0.1:{self.server.server_port}',
            '--token-file', str(self.token), *args,
        ], capture_output=True, text=True, timeout=5)

    def test_default_wait_submits_only_once(self):
        self.server.finish_after = 2
        result = self.run_client('downloads', 'run')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads(result.stdout)['terminal'])
        self.assertEqual(self.server.submissions, 1)
        self.assertNotIn('fixture-token', result.stdout + result.stderr)

    def test_polling_limit_preserves_id_and_request_file_reconnects(self):
        record = str(self.root / 'request.json')
        result = self.run_client('--request-file', record, '--wait-seconds', '0.001',
                                 'downloads', 'run')
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertFalse(json.loads(result.stdout)['terminal'])
        self.assertEqual(json.loads(Path(record).read_text())['requestId'], 'request-one')
        self.server.finished = True
        result = self.run_client('--request-file', record, 'downloads', 'run')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads(result.stdout)['terminal'])
        self.assertEqual(self.server.submissions, 1)

    def test_request_id_never_submits_again(self):
        self.server.finished = True
        result = self.run_client('--request-id', 'request-one')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.server.submissions, 0)

    def test_request_file_cannot_be_reused_for_another_command(self):
        record = str(self.root / 'request.json')
        self.server.finished = True
        self.assertEqual(self.run_client('--request-file', record, 'downloads', 'start').returncode, 0)
        self.assertEqual(self.run_client('--request-file', record, 'downloads', 'run').returncode, 2)
        self.assertEqual(self.server.submissions, 1)

    def test_concurrent_client_cannot_submit_using_the_same_request_file(self):
        record = str(self.root / 'request.json')
        with open(record + '.lock', 'w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_client('--request-file', record, 'downloads', 'run')
        self.assertEqual(result.returncode, 75)
        self.assertEqual(self.server.submissions, 0)


if __name__ == '__main__':
    unittest.main()
