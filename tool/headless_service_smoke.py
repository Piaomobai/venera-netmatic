#!/usr/bin/env python3
"""Verify separate API/worker processes with fixture-only data and loopback DAV."""
import argparse
import http.client
import http.server
import json
import os
from pathlib import Path
import secrets
import select
import signal
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
from headless_smoke_test import Dav, SOURCE


def ready(process, timeout=20):
    deadline = time.monotonic() + timeout
    messages = []
    while time.monotonic() < deadline:
        readable, _, _ = select.select([process.stdout], [], [], 0.2)
        if readable:
            line = process.stdout.readline()
            if not line:
                break
            message = json.loads(line)
            messages.append(message)
            if message.get('ready') or (message.get('data') or {}).get('state') == 'ready':
                return message
        if process.poll() is not None:
            break
    raise AssertionError(('Service did not become ready', process.poll(), messages))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--executable', required=True)
    parser.add_argument('--profile-root', required=True)
    parser.add_argument('--api-script', default='docker/api_server.py')
    args = parser.parse_args()
    root = Path(args.profile_root)
    root.mkdir(parents=True, exist_ok=True)
    # Unix socket paths must remain short, particularly inside the macOS sandbox.
    socket_path = root / ('s' + secrets.token_hex(4))
    executable = str(Path(args.executable).resolve())
    api_script = str(Path(args.api_script).resolve())
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Dav)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    children = []
    try:
        with tempfile.TemporaryDirectory(prefix='venera-service-', dir=root) as temp:
            profile = Path(temp)
            (profile / 'comic_source').mkdir()
            source = SOURCE.replace('explore = [];', '''explore = [];
  rankingCalls = 0;
  category = {title: "Fixture", parts: [], enableRankingPage: true};
  categoryComics = { ranking: {
    options: ["day-Day"],
    load: async (option, page) => {
      this.rankingCalls++;
      await new Promise(resolve => setTimeout(resolve, 1500));
      return {comics: [{id: "rank" + page, title: "Ranking", cover: "http://127.0.0.1:PORT/image.png", tags: []}], maxPage: 20};
    }
  }};''')
            source = source.replace('search = { load: async (query, options, page) => {',
                '''search = { load: async (query, options, page) => {
    if (query === "slow") await new Promise(resolve => setTimeout(resolve, 3500));''')
            source = source.replace('title: query,', 'title: query === "ranking-count" ? String(this.rankingCalls) : query,')
            (profile / 'comic_source' / 'fixture.js').write_text(source.replace('PORT', str(server.server_port)))
            settings = {'nasConnections': [{'id': 'nas', 'name': 'Fixture NAS', 'protocol': 'webdav',
                'host': f'http://127.0.0.1:{server.server_port}', 'username': 'fixture',
                'password': 'fixture-password', 'remotePath': 'Venera'}]}
            (profile / 'appdata.json').write_text(json.dumps({'settings': settings, 'searchHistory': []}))
            token = secrets.token_hex(32)
            token_file = profile / 'api-token'
            token_file.write_text(token)
            worker = subprocess.Popen([executable, '--headless', '--json', '--data-dir', str(profile),
                'service', 'serve', '--socket', str(socket_path)], stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, text=True)
            children.append(worker)
            worker_ready = ready(worker)['data']
            def gateway():
                process = subprocess.Popen(['python3', api_script, '--socket', str(socket_path),
                    '--host', '127.0.0.1', '--port', '0', '--token-file', str(token_file)],
                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
                children.append(process)
                return process, ready(process)
            api, endpoint = gateway()
            base = 'http://127.0.0.1:' + str(endpoint['port'])
            assert worker_ready['pid'] != endpoint['pid']
            def call(path, body=None, authorized=True):
                headers = {'Content-Type': 'application/json'}
                if authorized:
                    headers['Authorization'] = 'Bearer ' + token
                request = urllib.request.Request(base + path,
                    None if body is None else json.dumps(body).encode(), headers=headers)
                try:
                    with urllib.request.urlopen(request, timeout=10) as response:
                        return response.status, json.load(response)
                except urllib.error.HTTPError as error:
                    return error.code, json.load(error)
            def submit(command):
                code, response = call('/v1/commands', {'args': command})
                assert code == 202, response
                return response['data']['id']
            def wait(request_id, success=True):
                for _ in range(300):
                    code, response = call('/v1/requests/' + request_id)
                    assert code == 200, response
                    item = response['data']
                    if item['state'] not in ['queued', 'running']:
                        if success:
                            assert item['state'] == 'completed', item
                            assert item['exitCode'] == 0, item
                        return item
                    time.sleep(0.05)
                raise AssertionError('Request did not finish')
            assert call('/v1/status', authorized=False)[0] == 401
            status = call('/v1/status')[1]['data']
            assert status['pid'] == worker.pid
            assert status['queuePolicy']['maxBackgroundQueries'] == 1
            assert status['queuePolicy']['reservedInteractivePending'] == 32
            other = subprocess.run([executable, '--headless', '--json', '--data-dir', str(profile),
                'library', 'list'], capture_output=True, text=True, timeout=20)
            assert other.returncode == 3, (other.returncode, other.stdout, other.stderr[-1000:])
            assert json.loads(other.stdout.splitlines()[-1])['code'] == 'app_busy'
            assert call('/v1/commands', {'args': ['library', 'list', '--data-dir', '/other']})[0] == 400
            assert call('/v1/commands', {'args': ['scheduler', 'serve']})[0] == 400
            result = wait(submit(['search', 'fixture', 'query']))
            assert result['result']['data']['items'][0]['title'] == 'query'
            timed_out = wait(submit(['search', 'fixture', 'slow', '--timeout', '1']), success=False)
            assert timed_out['result']['code'] == 'timeout'
            assert timed_out['exitCode'] == 124
            slow = submit(['search', 'fixture', 'slow'])
            time.sleep(0.15)
            assert call('/v1/requests/' + slow + '/cancel', {})[0] == 200
            assert wait(slow, success=False)['result']['code'] == 'cancelled'
            wait(submit(['search', 'fixture', 'after-cancel']))
            ranking = wait(submit(['scheduler', 'create', 'rankingMonitor',
                '--schedule', '{"type":"interval","intervalSeconds":3600}',
                '--config', '{"sources":["fixture"],"pagesPerOption":20,"throttleMs":0}']))['result']['data']['id']
            ranking_run = wait(submit(['scheduler', 'run', ranking, '--timeout', '1']), success=False)
            assert ranking_run['result'].get('code') == 'timeout', ranking_run
            time.sleep(0.7)
            count = wait(submit(['search', 'fixture', 'ranking-count']))['result']['data']['items'][0]['title']
            assert count == '1', count
            assert wait(submit(['scheduler', 'history', ranking]))['result']['data']['runs'][0]['state'] == 'cancelled'
            wait(submit(['scheduler', 'delete', ranking]))
            # A transfer and live queries share the owner, never another app process.
            Dav.image_delay = 2.5
            download = submit(['downloads', 'add', 'fixture', 'book'])
            time.sleep(0.3)
            deferred_nas = submit(['nas', 'upload', 'nas', '--queue-timeout', '2'])
            assert call('/v1/requests/' + deferred_nas)[1]['data']['state'] == 'queued'
            wait(submit(['search', 'fixture', 'priority-query']))
            assert call('/v1/requests/' + download)[1]['data']['state'] == 'running'
            expired = wait(deferred_nas, success=False)
            assert expired['result']['code'] == 'queue_timeout'
            assert expired['exitCode'] == 124
            listing = wait(submit(['downloads', 'list']))
            assert listing['result']['data']['tasks']
            wait(submit(['scheduler', 'list']))
            # Restart the gateway without touching the owner or transfer.
            api.terminate(); api.wait(timeout=5)
            api, endpoint = gateway()
            base = 'http://127.0.0.1:' + str(endpoint['port'])
            assert call('/v1/status')[1]['data']['pid'] == worker.pid
            wait(download)
            Dav.image_delay = 0
            assert wait(submit(['library', 'list']))['result']['data']['total'] == 1
            wait(submit(['nas', 'upload', 'nas']))
            nas = wait(submit(['nas', 'library', 'nas']))['result']['data']
            assert nas['total'] == 1
            assert 'fixture-password' not in json.dumps(wait(submit(['nas', 'list'])))
            # Cancelling one API request leaves the owner and query channel alive.
            Dav.image_delay = 1
            cancelled = submit(['downloads', 'add', 'fixture', 'cancel-book'])
            time.sleep(0.3)
            assert call('/v1/requests/' + cancelled + '/cancel', {})[0] == 200
            assert wait(cancelled, success=False)['state'] == 'cancelled'
            assert wait(submit(['downloads', 'list']))['result']['data']['tasks']
            Dav.image_delay = 0
            wait(submit(['downloads', 'run']))
            assert wait(submit(['library', 'list']))['result']['data']['total'] == 2
            scheduled = wait(submit(['scheduler', 'create', 'incrementalDownload',
                '--run-on-start', '--schedule', '{"type":"interval","intervalSeconds":3600}',
                '--config', '{"scope":"library","nasConnectionId":"nas"}']))['result']['data']['id']
            # Queued requests are durable and the worker releases its lock on stop.
            worker.send_signal(signal.SIGTERM)
            worker.wait(timeout=15)
            assert worker.returncode == 130, (worker.returncode, worker.stdout.read())
            assert call('/healthz')[0] == 503
            source_path = profile / 'comic_source' / 'fixture.js'
            source_path.write_text(source_path.read_text().replace(
                'chapters: {one: "One"}', 'chapters: {one: "One", two: "Two"}'))
            Dav.image_delay = 0.5
            worker = subprocess.Popen([executable, '--headless', '--json', '--data-dir', str(profile),
                'service', 'serve', '--socket', str(socket_path)], stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, text=True)
            children.append(worker)
            ready(worker)
            assert call('/v1/status')[1]['data']['pid'] == worker.pid
            assert wait(submit(['library', 'list']))['result']['data']['total'] == 2
            assert call('/v1/requests/' + download)[1]['data']['state'] == 'completed'
            for _ in range(200):
                runs = wait(submit(['scheduler', 'history', scheduled]))['result']['data']['runs']
                if runs and runs[0]['state'] == 'success':
                    break
                time.sleep(0.1)
            else:
                raise AssertionError(('Automatic scheduled task did not complete', runs))
            local = wait(submit(['library', 'list']))['result']['data']['items']
            remote = wait(submit(['nas', 'library', 'nas']))['result']['data']['items']
            assert all(set(item['downloadedChapters']) == {'one', 'two'} for item in local)
            assert len(remote) == 2
            assert all(set(item['downloadedChapters']) == {'one', 'two'} for item in remote)
            print(json.dumps({'passed': True, 'checks': ['API authentication', 'separate PIDs',
                'runtime option isolation', 'source query', 'live query during download',
                'gateway restart leaves worker running', 'NAS upload and credential redaction',
                'request cancellation and queue resume', 'worker restart and persistent results',
                'automatic scheduled incremental download and NAS sync',
                'worker excludes other CLI owners', 'query priority over queued NAS work',
                'queued NAS deadline', 'stalled query execution deadline and cancellation',
                'ranking cancellation while waiting for a page']}, indent=2))
    finally:
        Dav.image_delay = 0
        for child in reversed(children):
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    child.kill(); child.wait()
        if socket_path.exists():
            socket_path.unlink()
        server.shutdown(); server.server_close()

if __name__ == '__main__':
    main()
