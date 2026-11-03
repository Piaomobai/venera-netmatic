#!/usr/bin/env python3
"""Exercise native CLI and gateway account lifecycles with dummy credentials.
Optionally use an installed picacg script against the same loopback API.
Never reads a real account profile or sends credentials to the public internet.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import http.server
import json
import os
from pathlib import Path
import secrets
import signal
import sqlite3
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
from headless_service_smoke import ready


class AuthApi(http.server.BaseHTTPRequestHandler):
    users = {'alice': 'fixture-alice-password', 'bob': 'fixture-bob-password', 'slow': 'fixture-slow-password'}
    tokens = {}
    issued_tokens = set()
    login_count = 0
    login_delay = 0
    lock = threading.RLock()

    def log_message(self, *_):
        pass

    def reply(self, status, body, cookie=None):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        if cookie:
            self.send_header('Set-Cookie', 'sid=' + cookie + '; Path=/; HttpOnly')
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def user(self):
        with self.lock:
            return self.tokens.get(self.headers.get('authorization'))

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))))
        if self.path == '/auth/sign-in':
            user, password = body.get('email'), body.get('password')
            with self.lock:
                AuthApi.login_count += 1
            time.sleep(1.5 if user == 'slow' else self.login_delay)
            if user == 'rate':
                return self.reply(429, {'error': 'rate limited'})
            if user == 'network':
                self.close_connection = True
                return
            if user == 'malformed':
                return self.reply(200, {'data': {}})
            if self.users.get(user) != password:
                return self.reply(401, {'error': 'private response', 'echo': body})
            token = secrets.token_hex(16)
            with self.lock:
                self.tokens[token] = user
                self.issued_tokens.add(token)
            return self.reply(200, {'data': {'token': token}}, cookie=token)
        if self.path.startswith('/comics/advanced-search?'):
            query = body.get('keyword')
            if query == 'slow-query':
                time.sleep(1.5)
            user = self.user()
            if not user:
                return self.reply(401, {})
            comic = {'id': 'book', '_id': 'book', 'title': user + ':' + query, 'cover': '', 'tags': [],
                     'author': 'Fixture', 'categories': [], 'thumb': {'fileServer': 'http://127.0.0.1', 'path': 'cover.png'}}
            return self.reply(200, {'data': {'comics': {'docs': [comic], 'pages': 1}}})
        self.reply(404, {})

    def do_GET(self):
        if not self.user():
            return self.reply(401, {})
        if self.path == '/comics/random':
            return self.reply(200, {'data': {'comics': []}})
        if self.path.startswith('/comics/leaderboard?') or self.path.startswith('/comics?'):
            comic = {'id': 'book', '_id': 'book', 'title': 'Fixture browse', 'cover': '', 'tags': [],
                     'author': 'Fixture', 'categories': [], 'thumb': {'fileServer': 'http://127.0.0.1', 'path': 'cover.png'}}
            comics = [comic] if self.path.startswith('/comics/leaderboard?') else {'docs': [comic], 'pages': 1}
            return self.reply(200, {'data': {'comics': comics}})
        if self.path == '/comics/book':
            comic = {'title': 'Fixture details', 'author': 'Fixture', 'thumb': {'fileServer': 'http://127.0.0.1', 'path': 'cover.png'},
                     'description': '', 'categories': [], 'tags': [], 'updated_at': '2026-11-03T00:00:00Z', '_creator': {'name': 'Fixture'}}
            return self.reply(200, {'data': {'title': 'Fixture details', 'comic': comic}})
        if self.path.startswith('/comics/book/eps?'):
            return self.reply(200, {'data': {'eps': {'docs': [{'order': 1, 'title': 'One'}], 'pages': 1}}})
        if self.path == '/comics/book/recommendation':
            return self.reply(200, {'data': {'comics': []}})
        self.reply(404, {})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--executable', required=True)
    parser.add_argument('--profile-root', required=True)
    parser.add_argument('--fixture', default='test/fixtures/headless_auth_source.js')
    parser.add_argument('--picacg-script', help='Optional script ONLY; do not supply any .data file')
    parser.add_argument('--api-script', default='docker/api_server.py')
    parser.add_argument('--report', help='Optional JSON verification report (never includes credentials)')
    args = parser.parse_args()
    root = Path(args.profile_root); root.mkdir(parents=True, exist_ok=True)
    executable = str(Path(args.executable).resolve())
    template = Path(args.picacg_script or args.fixture).read_text()
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), AuthApi)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    children, passed, outputs = [], [], []
    socket_path = root / ('a' + secrets.token_hex(4))
    def record(name):
        passed.append(name)
    try:
        with tempfile.TemporaryDirectory(prefix='venera-auth-', dir=root) as scratch:
            profile = Path(scratch); profile.chmod(0o700)
            (profile / 'comic_source').mkdir()
            (profile / 'comic_source/picacg.js').write_text(template.replace('PORT', str(server.server_port)))
            old_comic = profile / 'existing-comic/image.bin'
            old_comic.parent.mkdir(); old_comic.write_bytes(b'existing downloaded comic')
            data_file = profile / 'comic_source/picacg.data'
            data_file.write_text(json.dumps({'settings': {'base_url': f'http://127.0.0.1:{server.server_port}'}}))
            def credentials(user, password=None):
                return {'username': user, 'password': password or AuthApi.users.get(user, 'fixture-invalid-password')}
            def cli(*command, user=None, payload=None, stdin=False, code=0):
                argv = [executable, '--headless', '--json', '--data-dir', str(profile), *command]
                value = payload if payload is not None else credentials(user) if user else None
                if value is not None:
                    if stdin:
                        argv.append('--credentials-stdin')
                    else:
                        private_file = profile / 'credentials.json'
                        private_file.write_text(json.dumps(value)); private_file.chmod(0o600)
                        argv += ['--credentials-file', str(private_file)]
                result = subprocess.run(argv, input=json.dumps(value) if stdin else None,
                    capture_output=True, text=True, timeout=30)
                outputs.extend([result.stdout, result.stderr])
                values = [json.loads(line) for line in result.stdout.splitlines()]
                assert result.returncode == code, (command, result.returncode, values[-1])
                return values[-1]
            assert cli('sources', 'status', 'picacg')['data']['state'] == 'logged_out'
            assert cli('search', 'picacg', 'before-login', code=1)['code'] == 'authentication_required'
            assert cli('sources', 'login', 'picacg', user='alice')['data']['state'] == 'authenticated'
            assert cli('search', 'picacg', 'first')['data']['items'][0]['title'] == 'alice:first'
            record('CLI source selection, private-file login, remote verification and restart reuse')
            assert set(cli('ranking', 'options', 'picacg')['data']['options']) == {'H24', 'D7', 'D30'}
            for option in ['H24', 'D7', 'D30']:
                assert len(cli('ranking', 'get', 'picacg', option)['data']['items']) == 1
            catalog = cli('categories', 'list', 'picacg')['data']
            assert catalog['total'] >= 1
            category = catalog['items'][0]['label']
            assert cli('categories', 'options', 'picacg', category)['data']['options']
            assert len(cli('categories', 'get', 'picacg', category)['data']['items']) == 1
            assert cli('tags', 'resolve', 'picacg', 'Tags', 'fixture-tag')['data']['target']['action'] == 'search'
            assert cli('tags', 'resolve', 'picacg', 'Categories', category)['data']['target']['action'] == 'category'
            record('ranking periods, category catalog, sort options, browsing and tag query targets')
            assert cli('sources', 'login', 'picacg', user='bob', code=1)['code'] == 'already_logged_in'
            assert cli('search', 'picacg', 'unchanged')['data']['items'][0]['title'] == 'alice:unchanged'
            assert cli('sources', 'login', 'picacg', '--replace', user='bob',
                       payload=credentials('bob', 'private-failed-password'), code=1)['code'] == 'authentication_failed'
            data = json.loads(data_file.read_text())
            assert 'account' not in data and 'token' not in data and 'settings' in data
            assert cli('sources', 'login', 'picacg', user='bob', stdin=True)['data']['state'] == 'authenticated'
            assert cli('search', 'picacg', 'switched')['data']['items'][0]['title'] == 'bob:switched'
            record('explicit replacement, failed-switch cleanup, different-account retry and stdin')
            with AuthApi.lock:
                AuthApi.tokens.clear()
            assert cli('sources', 'verify', 'picacg', code=1)['data']['state'] == 'expired'
            assert cli('sources', 'reauth', 'picacg')['data']['state'] == 'authenticated'
            with AuthApi.lock:
                AuthApi.tokens.clear()
            assert cli('comic', 'get', 'picacg', 'book')['status'] == 'success'
            record('expired-session status, explicit reauthentication and detail 401 recovery')
            assert cli('sources', 'logout', 'picacg')['data']['state'] == 'logged_out'
            assert cli('sources', 'logout', 'picacg')['status'] == 'success'
            db = sqlite3.connect(str(profile / 'cookie.db'))
            assert db.execute("SELECT count(*) FROM cookies WHERE name='sid'").fetchone()[0] == 0
            db.close()
            assert os.name == 'nt' or data_file.stat().st_mode & 0o777 == 0o600
            assert not Path(str(data_file) + '.tmp').exists()
            record('idempotent logout, cookie revocation and atomic private session storage')
            assert cli('sources', 'login', 'picacg', user='rate', code=1)['code'] == 'auth_rate_limited'
            assert cli('sources', 'login', 'picacg', user='network', code=1)['code'] == 'network_error'
            assert cli('sources', 'login', 'picacg', user='malformed', code=1)['code'] == 'auth_invalid_response'
            assert cli('sources', 'login', 'picacg', '--timeout', '1', user='slow', code=124)['code'] == 'timeout'
            assert cli('sources', 'status', 'picacg')['data']['state'] == 'logged_out'
            record('rate limiting, connection failure and timeout rollback without late login')
            if not args.picacg_script:
                assert cli('sources', 'login', 'picacg', user='captcha', code=1)['code'] == 'interaction_required'
                record('GUI interaction-required result is explicit and leaves no session')

            # Start the real worker and gateway; all HTTP auth calls remain async.
            token = secrets.token_hex(32)
            token_file = profile / 'api-token'; token_file.write_text(token); token_file.chmod(0o600)
            def start_worker():
                p = subprocess.Popen([executable, '--headless', '--json', '--data-dir', str(profile),
                    'service', 'serve', '--socket', str(socket_path)], stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL, text=True)
                children.append(p); ready(p); return p
            worker = start_worker()
            api = subprocess.Popen(['python3', str(Path(args.api_script).resolve()), '--socket', str(socket_path),
                '--port', '0', '--token-file', str(token_file)], stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, text=True)
            children.append(api)
            base = 'http://127.0.0.1:' + str(ready(api)['port'])
            def call(path, body=None):
                request = urllib.request.Request(base + path, None if body is None else json.dumps(body).encode(),
                    headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
                try:
                    with urllib.request.urlopen(request, timeout=10) as response:
                        return response.status, json.load(response)
                except urllib.error.HTTPError as error:
                    return error.code, json.load(error)
            def auth(action, user=None, **options):
                body = {'sourceKey': 'picacg', 'action': action, **options}
                if user: body['credentials'] = credentials(user)
                code, response = call('/v1/source-auth', body)
                assert code == 202, response
                return response['data']['id']
            def submit(command):
                code, response = call('/v1/commands', {'args': command}); assert code == 202, response
                return response['data']['id']
            def wait(request_id, expected=None):
                for _ in range(400):
                    code, response = call('/v1/requests/' + request_id); assert code == 200, response
                    item = response['data']
                    if item['state'] not in ['running', 'queued']:
                        outputs.append(json.dumps(item))
                        if expected:
                            assert item['result'].get('code') == expected, item
                        else:
                            assert item['exitCode'] == 0, item
                        return item
                    time.sleep(0.025)
                raise AssertionError('Auth request did not finish')
            assert call('/v1/commands', {'args': ['sources', 'login', 'picacg', '--credentials-file', '/etc/passwd']})[0] == 400
            wait(auth('login', 'alice'))
            wait(auth('login', 'bob'), 'already_logged_in')
            wait(auth('login', credentials=credentials('bob', 'private-failed-password'), replace=True), 'authentication_failed')
            wait(auth('logout'))
            wait(auth('login', 'bob'))
            record('dedicated HTTP auth endpoint, rejection, logout and account replacement')

            with AuthApi.lock:
                AuthApi.tokens.clear()
                before = AuthApi.login_count
            AuthApi.login_delay = 0.25
            with ThreadPoolExecutor(max_workers=4) as pool:
                requests = list(pool.map(lambda n: submit(['search', 'picacg', 'parallel-' + str(n)]), range(4)))
            for request in requests: wait(request)
            assert AuthApi.login_count == before + 1, (before, AuthApi.login_count)
            AuthApi.login_delay = 0
            record('four concurrent expired searches share a single token renewal')

            with AuthApi.lock:
                AuthApi.tokens.clear()
                AuthApi.users['bob'] = 'fixture-changed-password'
            wait(submit(['search', 'picacg', 'expired-password']), 'authentication_required')
            before = AuthApi.login_count
            wait(submit(['search', 'picacg', 'expired-password-again']), 'authentication_required')
            assert AuthApi.login_count == before
            assert wait(auth('status'))['result']['data']['state'] == 'expired'
            AuthApi.users['bob'] = 'fixture-bob-password'
            wait(auth('reauth'))
            record('rejected automatic renewal marks expiry and stops repeated password attempts')

            wait(auth('logout'))
            request = auth('login', 'slow')
            time.sleep(0.25)
            assert call('/v1/requests/' + request + '/cancel', {})[0] == 200
            wait(request, 'cancelled')
            assert wait(auth('status'))['result']['data']['state'] == 'logged_out'
            wait(auth('login', 'alice'))
            record('cancelled in-flight login settles and rolls back before a new account can start')

            with AuthApi.lock:
                AuthApi.tokens.clear()
            slow_query = submit(['search', 'picacg', 'slow-query', '--timeout', '1'])
            wait(slow_query, 'timeout')
            wait(auth('login', 'bob', replace=True))
            result = wait(submit(['search', 'picacg', 'after-old-query']))
            assert result['result']['data']['items'][0]['title'] == 'bob:after-old-query'
            record('account replacement waits for timed-out source promises')

            wait(auth('logout'))
            crashed = auth('login', 'slow')
            time.sleep(0.25)
            worker.kill(); worker.wait(timeout=10)
            worker = start_worker()
            wait(crashed, 'interrupted')
            assert wait(auth('status'))['result']['data']['state'] == 'logged_out'
            wait(auth('login', 'bob'))
            record('worker crash leaves no staged token and does not replay credentials on restart')
            journal = (profile / 'service_requests.json').read_text()
            logs = (profile / 'logs.txt').read_text() if (profile / 'logs.txt').exists() else ''
            serialized = '\n'.join(outputs) + journal + logs
            for secret in [*AuthApi.users.values(), 'private-failed-password']:
                assert secret not in serialized, 'Credential appeared in output or request journal'
            for session_token in AuthApi.issued_tokens:
                if session_token in serialized:
                    channels = [('CLI/API output ' + str(i), value) for i, value in enumerate(outputs)]
                    channels += [('journal', journal), ('logs', logs)]
                    locations = []
                    for channel, value in channels:
                        position = value.find(session_token)
                        if position < 0:
                            continue
                        excerpt = value[max(0, position - 160):position + len(session_token) + 160]
                        for secret in [*AuthApi.issued_tokens, *AuthApi.users.values(), 'private-failed-password']:
                            excerpt = excerpt.replace(secret, '[REDACTED]')
                        locations.append({'channel': channel, 'excerpt': excerpt})
                    raise AssertionError(('Token appeared in output or request journal', locations))
            assert old_comic.read_bytes() == b'existing downloaded comic'
            record('passwords and session tokens absent from CLI/API results, logs and journal')
    finally:
        for child in reversed(children):
            if child.poll() is None:
                child.terminate()
                try: child.wait(timeout=20)
                except subprocess.TimeoutExpired: child.kill(); child.wait(timeout=5)
        if socket_path.exists(): socket_path.unlink()
        server.shutdown(); server.server_close()
    report = {'passed': passed, 'count': len(passed), 'realAccountUsed': False,
              'source': 'installed-picacg-script' if args.picacg_script else 'local-fixture'}
    if args.report:
        Path(args.report).write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report, ensure_ascii=False))


if __name__ == '__main__':
    main()
