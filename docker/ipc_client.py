"""Private worker socket protocol. No app data or credentials are read here."""
import json
import socket
import sys

MAX_MESSAGE = 2 * 1024 * 1024

def call_worker(path, message, timeout=5):
    payload = json.dumps(message, separators=(',', ':')).encode() + b'\n'
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(timeout)
        connection.connect(path)
        connection.sendall(payload)
        with connection.makefile('rb') as stream:
            data = stream.readline(MAX_MESSAGE + 1)
    if not data or len(data) > MAX_MESSAGE:
        raise ValueError('Invalid worker response')
    return json.loads(data)

if __name__ == '__main__':
    response = call_worker(sys.argv[1], {'op': sys.argv[2] if len(sys.argv) > 2 else 'health'})
    print(json.dumps(response))
    sys.exit(0 if response.get('ok') else 1)
