#!/usr/bin/env python3
"""Exercise the HTTP tag display switch with a fixture-only Unix socket worker."""
from contextlib import contextmanager
import json
import os
from pathlib import Path
import select
import socketserver
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request


ROOT = Path(__file__).resolve().parent.parent
RECORDS = {
    'search': {
        'items': [
            {'id': 'one', 'tags': ['Adventure', ' ＨＩＤＤＥＮ ', '校服', 'Internal note']},
            {'id': 'two', 'tags': ['Hidden']},
        ],
        'page': 1,
        'maxPage': 3,
    },
    'details': {
        'comicId': 'one',
        'title': 'Hidden in the title',
        'description': 'Internal note in a description',
        'tags': {'Tags': ['Adventure', 'Hidden', '制服'], 'Other': ['Hidden']},
    },
    'library': {
        'items': [
            {'id': 'one', 'tags': ['Tags:Hidden', 'Tags:Adventure', 'Other:Hidden']},
            {'id': 'two', 'tags': None},
        ],
    },
}


class Worker(socketserver.StreamRequestHandler):
    def handle(self):
        message = json.loads(self.rfile.readline())
        if message['op'] == 'health':
            response = {'ok': True}
        elif message['op'] == 'submit':
            response = {'ok': True, 'data': {'id': 'search', 'state': 'queued'}}
        else:
            response = {
                'ok': True,
                'data': {'state': 'completed', 'result': {'data': RECORDS[message['id']]}},
            }
        self.wfile.write(json.dumps(response).encode() + b'\n')


class GatewayTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Unix socket path limits are particularly short on macOS.
        cls.temp = tempfile.TemporaryDirectory(prefix='venera-api-', dir='/tmp')
        cls.root = Path(cls.temp.name)
        cls.socket = cls.root / 'worker.sock'
        cls.token = 'fixture-token-' + 'x' * 32
        cls.token_file = cls.root / 'token'
        cls.token_file.write_text(cls.token)
        cls.token_file.chmod(0o600)
        cls.worker = socketserver.UnixStreamServer(str(cls.socket), Worker)
        cls.thread = threading.Thread(target=cls.worker.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.worker.shutdown()
        cls.worker.server_close()
        cls.thread.join(timeout=5)
        cls.temp.cleanup()

    def command(self, *flags):
        return [
            sys.executable, '-B', str(ROOT / 'docker/api_server.py'),
            '--socket', str(self.socket), '--token-file', str(self.token_file),
            '--host', '127.0.0.1', '--port', '0', *flags,
        ]

    def environment(self, overrides):
        env = {key: value for key, value in os.environ.items()
               if not key.startswith('VENERA_AI_')}
        env.update(overrides)
        return env

    @contextmanager
    def gateway(self, *flags, **environment):
        with subprocess.Popen(self.command(*flags), env=self.environment(environment),
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True) as process:
            try:
                self.assertTrue(select.select([process.stdout], [], [], 5)[0],
                                'Gateway did not report readiness')
                line = process.stdout.readline()
                if not line:
                    self.fail(process.stderr.read())
                ready = json.loads(line)
                self.assertTrue(ready['ready'])
                yield 'http://127.0.0.1:' + str(ready['port'])
            finally:
                process.terminate()
                process.wait(timeout=5)

    def call(self, base, path, body=None, authorized=True):
        headers = {'Content-Type': 'application/json'}
        if authorized:
            headers['Authorization'] = 'Bearer ' + self.token
        request = urllib.request.Request(
            base + path, None if body is None else json.dumps(body).encode(), headers
        )
        with urllib.request.urlopen(request, timeout=5) as response:
            return response.status, json.load(response)

    def result(self, base, name):
        return self.call(base, '/v1/requests/' + name)[1]['data']['result']['data']

    def test_default_off_preserves_configured_tags(self):
        with self.gateway(VENERA_AI_HIDDEN_TAGS='["hidden"]',
                          VENERA_AI_HIDDEN_TAG_FRAGMENTS='["internal"]') as base:
            for name, expected in RECORDS.items():
                self.assertEqual(self.result(base, name), expected)

    def test_enabled_filters_nested_and_flat_tags_without_removing_comics(self):
        with self.gateway('--hide-tags', '--hidden-tags', '["hidden"]',
                          '--hidden-tag-fragments', '["internal"]') as base:
            status, submitted = self.call(base, '/v1/commands', {'args': ['search', 'fixture', 'query']})
            self.assertEqual(status, 202)
            self.assertEqual(submitted['data']['id'], 'search')
            self.assertEqual(self.result(base, 'search'), {
                'items': [{'id': 'one', 'tags': ['Adventure', '校服']},
                          {'id': 'two', 'tags': []}],
                'page': 1, 'maxPage': 3,
            })
            self.assertEqual(self.result(base, 'details'), {
                **RECORDS['details'],
                'tags': {'Tags': ['Adventure', '制服'], 'Other': []},
            })
            self.assertEqual(self.result(base, 'library'), {
                'items': [{'id': 'one', 'tags': ['Tags:Adventure']},
                          {'id': 'two', 'tags': None}],
            })
            # Re-reading an existing result uses the same output filter.
            self.assertEqual(self.result(base, 'search')['items'][1]['tags'], [])
            self.assertEqual(self.call(base, '/healthz', authorized=False), (200, {'ok': True}))
            with self.assertRaises(urllib.error.HTTPError) as error:
                self.call(base, '/v1/requests/search', authorized=False)
            self.assertEqual(error.exception.code, 401)

    def test_namespace_specific_rule_matches_both_storage_formats(self):
        with self.gateway('--hide-tags', '--hidden-tags', '["Tags:Hidden"]') as base:
            self.assertEqual(self.result(base, 'details')['tags'],
                             {'Tags': ['Adventure', '制服'], 'Other': ['Hidden']})
            self.assertEqual(self.result(base, 'library')['items'][0]['tags'],
                             ['Tags:Adventure', 'Other:Hidden'])

    def test_enabled_with_empty_lists_preserves_results(self):
        with self.gateway('--hide-tags') as base:
            self.assertEqual(self.result(base, 'details'), RECORDS['details'])

    def test_environment_switch_and_explicit_flag_precedence(self):
        for value in ('true', '1'):
            with self.subTest(value=value):
                with self.gateway(VENERA_AI_HIDE_TAGS=value,
                                  VENERA_AI_HIDDEN_TAGS='["hidden"]') as base:
                    self.assertEqual(self.result(base, 'search')['items'][1]['tags'], [])
        for value in ('false', '0'):
            with self.subTest(value=value):
                with self.gateway(VENERA_AI_HIDE_TAGS=value,
                                  VENERA_AI_HIDDEN_TAGS='["hidden"]') as base:
                    self.assertEqual(self.result(base, 'search'), RECORDS['search'])
        with self.gateway('--no-hide-tags', VENERA_AI_HIDE_TAGS='true',
                          VENERA_AI_HIDDEN_TAGS='["hidden"]') as base:
            self.assertEqual(self.result(base, 'search'), RECORDS['search'])
        with self.gateway('--hide-tags', VENERA_AI_HIDE_TAGS='false',
                          VENERA_AI_HIDDEN_TAGS='["hidden"]') as base:
            self.assertEqual(self.result(base, 'search')['items'][1]['tags'], [])

    def test_invalid_configuration_rejected_before_listening(self):
        cases = [
            {'VENERA_AI_HIDE_TAGS': 'maybe'},
            {'VENERA_AI_HIDDEN_TAGS': 'not-json'},
            {'VENERA_AI_HIDDEN_TAGS': '{}'},
            {'VENERA_AI_HIDDEN_TAGS': '[1]'},
            {'VENERA_AI_HIDDEN_TAG_FRAGMENTS': '[" "]'},
        ]
        for environment in cases:
            with self.subTest(environment=environment):
                process = subprocess.run(self.command(), env=self.environment(environment),
                                         capture_output=True, text=True, timeout=5)
                self.assertEqual(process.returncode, 2)
                self.assertEqual(process.stdout, '')


if __name__ == '__main__':
    unittest.main()
