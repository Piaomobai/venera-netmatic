"""Submit once and poll the same request; reconnect using its saved ID."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import sys
import time
import urllib.error
import urllib.request

TERMINAL = {'completed', 'failed', 'cancelled', 'interrupted'}


def call(base, token, path, body=None):
    request = urllib.request.Request(
        base + path, data=None if body is None else json.dumps(body).encode(),
        headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=10) as response:
        result = json.load(response)
    if not result.get('ok'):
        raise ValueError('API rejected the request')
    return result['data']


def follow(base, token, request_id, wait_seconds):
    started = time.monotonic()
    while True:
        try:
            item = call(base, token, '/v1/requests/' + request_id)
        except (OSError, ValueError):
            print(json.dumps({'requestId': request_id, 'terminal': False,
                              'code': 'poll_unavailable'}), flush=True)
            return 75
        if item['state'] in TERMINAL:
            print(json.dumps({'requestId': request_id, 'terminal': True, **item},
                             ensure_ascii=False), flush=True)
            return item.get('exitCode', 1)
        if wait_seconds and time.monotonic() - started >= wait_seconds:
            print(json.dumps({'requestId': request_id, 'terminal': False,
                              'state': item['state'], 'code': 'still_pending'}), flush=True)
            return 75
        time.sleep(0.5)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', default='http://127.0.0.1:8080')
    parser.add_argument('--token-file', required=True)
    parser.add_argument('--request-id')
    parser.add_argument('--request-file', help='Reuse this request instead of submitting again')
    parser.add_argument('--wait-seconds', type=float, default=0,
                        help='Local polling limit; 0 waits until the request is terminal')
    parser.add_argument('args', nargs=argparse.REMAINDER)
    options = parser.parse_args(argv)
    if options.wait_seconds < 0:
        parser.error('--wait-seconds cannot be negative')
    base = options.url.rstrip('/')
    token = Path(options.token_file).read_text().strip()
    command = options.args[1:] if options.args[:1] == ['--'] else options.args
    if options.request_id and command:
        parser.error('Use --request-id without a new command')
    record = Path(options.request_file) if options.request_file else None
    lock = None
    request_id = options.request_id
    try:
        if record:
            lock = open(str(record) + '.lock', 'a')
            os.chmod(lock.name, 0o600)
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                print(json.dumps({'terminal': False, 'code': 'client_already_running'}))
                return 75
            if record.exists():
                saved = json.loads(record.read_text())
                if saved['url'] != base or (command and saved['args'] != command):
                    parser.error('The request file belongs to a different endpoint or command')
                if request_id and request_id != saved['requestId']:
                    parser.error('The request file belongs to a different request')
                request_id = saved['requestId']
        if not request_id:
            if not command:
                parser.error('Provide a command, --request-id or existing --request-file')
            # A failed POST is never automatically retried: acceptance may be ambiguous.
            request_id = call(base, token, '/v1/commands', {'args': command})['id']
            print(json.dumps({'requestId': request_id, 'terminal': False}), file=sys.stderr, flush=True)
            if record:
                temporary = record.with_name(record.name + '.tmp')
                descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                with os.fdopen(descriptor, 'w') as output:
                    json.dump({'requestId': request_id, 'url': base, 'args': command}, output)
                    output.flush()
                    os.fsync(output.fileno())
                temporary.replace(record)
        return follow(base, token, request_id, options.wait_seconds)
    except (OSError, ValueError):
        print(json.dumps({'requestId': request_id, 'terminal': False,
                          'code': 'client_error'}), flush=True)
        return 75
    finally:
        if lock:
            lock.close()


if __name__ == '__main__':
    sys.exit(main())
