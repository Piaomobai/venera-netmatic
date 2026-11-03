#!/usr/bin/env python3
"""Exercise the real Compose boundary using disposable volumes and credentials."""
import argparse
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--build', action='store_true')
    parser.add_argument('--docker-config', help='Optional isolated Docker CLI config directory')
    options = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    docker = ['docker']
    if options.docker_config:
        docker += ['--config', str(Path(options.docker_config).resolve())]
    project = 'venera-verify-' + secrets.token_hex(4)
    with socket.socket() as available:
        available.bind(('127.0.0.1', 0))
        port = available.getsockname()[1]
    # Keep file secrets inside the build context's ignored directory, including
    # on Docker Desktop/Colima where only workspace paths may be shared.
    (root / 'build').mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='compose-check-', dir=root / 'build') as temp:
        token = secrets.token_hex(32)
        token_file = Path(temp) / 'api-token'
        token_file.write_text(token + '\n')
        token_file.chmod(0o444)
        env = dict(os.environ, VENERA_API_TOKEN_FILE=str(token_file), VENERA_API_PORT=str(port))
        compose = docker + ['compose', '-f', str(root / 'compose.yaml'), '-p', project]

        def run(*args):
            result = subprocess.run(list(args), cwd=root, env=env, capture_output=True, text=True)
            if result.returncode:
                raise RuntimeError(result.stderr[-4000:])
            return result.stdout.strip()

        def call(path, body=None, authorized=True):
            headers = {'Content-Type': 'application/json'}
            if authorized:
                headers['Authorization'] = 'Bearer ' + token
            request = urllib.request.Request('http://127.0.0.1:' + str(port) + path,
                None if body is None else json.dumps(body).encode(), headers=headers)
            try:
                with urllib.request.urlopen(request, timeout=10) as response:
                    return response.status, json.load(response)
            except urllib.error.HTTPError as error:
                return error.code, json.load(error)

        def healthy():
            for _ in range(180):
                try:
                    if call('/healthz', authorized=False)[0] == 200:
                        return
                except (OSError, ValueError):
                    pass
                time.sleep(0.5)
            raise AssertionError('Compose gateway/worker did not become healthy')

        def wait(request_id):
            for _ in range(200):
                status, response = call('/v1/requests/' + request_id)
                assert status == 200, response
                item = response['data']
                if item['state'] not in ['queued', 'running']:
                    assert item['exitCode'] == 0, item
                    return item
                time.sleep(0.05)
            raise AssertionError('Command did not complete')

        try:
            if options.build:
                run(*compose, 'build')
            run(*compose, 'up', '-d', '--wait', '--wait-timeout', '180')
            healthy()
            assert call('/v1/status', authorized=False)[0] == 401
            code, invalid = call('/v1/source-auth', {'sourceKey': 'picacg', 'action': 'login',
                'credentials': {'username': '', 'password': ''}})
            assert code == 400 and invalid['code'] == 'invalid_credentials', invalid
            worker_id = run(*compose, 'ps', '-q', 'worker')
            api_id = run(*compose, 'ps', '-q', 'api')
            worker, api = json.loads(run(*docker, 'inspect', worker_id, api_id))
            assert worker['State']['Pid'] != api['State']['Pid']
            assert worker['Config']['User'] == api['Config']['User'] == '10001:10001'
            assert '/data' in {m['Destination'] for m in worker['Mounts']}
            assert {m['Destination'] for m in api['Mounts']} == {'/run/venera', '/run/secrets/api_token'}
            assert all(not m['RW'] for m in api['Mounts'])
            assert api['HostConfig']['PortBindings']['8080/tcp'][0]['HostIp'] == '127.0.0.1'
            status, submitted = call('/v1/commands', {'args': ['library', 'list']})
            assert status == 202, submitted
            request_id = submitted['data']['id']
            assert wait(request_id)['result']['data']['total'] == 0
            owner_pid = worker['State']['Pid']
            run(*compose, 'restart', 'api')
            healthy()
            assert json.loads(run(*docker, 'inspect', worker_id))[0]['State']['Pid'] == owner_pid
            assert wait(request_id)['state'] == 'completed'
            run(*compose, 'restart', 'worker')
            healthy()
            assert wait(request_id)['state'] == 'completed'
            run(*compose, 'kill', '--signal', 'SIGKILL', 'worker')
            run(*compose, 'up', '-d', 'worker')
            healthy()
            assert wait(request_id)['state'] == 'completed'
            print(json.dumps({'passed': True, 'checks': [
                'healthy independent containers', 'non-root socket access',
                'API has no application data mount', 'loopback-only authenticated API',
                'dedicated source-auth route reaches credential validation',
                'gateway restart preserves worker PID', 'worker restart preserves request journal',
                'recovery after abrupt container kill'
            ]}, indent=2))
        except Exception:
            print(run(*compose, 'logs', '--tail', '60'), flush=True)
            raise
        finally:
            run(*compose, 'down', '--volumes', '--remove-orphans')


if __name__ == '__main__':
    main()
