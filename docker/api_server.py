"""Authenticated HTTP gateway. The Flutter/scheduler process owns all data.
This process has only a Unix socket and API credential, never the app volume.
"""
import argparse
import hmac
import http.server
import json
import os
from pathlib import Path
import signal
import threading
import unicodedata
from urllib.parse import urlsplit
from ipc_client import call_worker

MAX_BODY = 256 * 1024

def normalize_tag(tag):
    return unicodedata.normalize('NFKC', tag).strip().casefold()

def filter_comic_tags(value, hidden_tags, hidden_fragments):
    """Filter comic tag fields in a decoded worker response."""
    def visible(tags, namespace=None):
        kept = []
        for tag in tags:
            if isinstance(tag, str):
                normalized = normalize_tag(tag)
                _, _, unqualified = normalized.partition(':')
                qualified = normalize_tag(f'{namespace}:{tag}') if namespace else normalized
                if (
                    normalized in hidden_tags
                    or unqualified.strip() in hidden_tags
                    or qualified in hidden_tags
                    or any(fragment in normalized for fragment in hidden_fragments)
                ):
                    continue
            kept.append(tag)
        return kept

    if isinstance(value, list):
        for entry in value:
            filter_comic_tags(entry, hidden_tags, hidden_fragments)
    elif isinstance(value, dict):
        tags = value.get('tags')
        if isinstance(tags, list):
            value['tags'] = visible(tags)
        elif isinstance(tags, dict):
            value['tags'] = {
                group: visible(tags_in_group, group) if isinstance(tags_in_group, list) else tags_in_group
                for group, tags_in_group in tags.items()
            }
        for key, entry in value.items():
            if key != 'tags':
                filter_comic_tags(entry, hidden_tags, hidden_fragments)

class Gateway(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, format, *args):
        # Do not log request paths, tokens, searches or command arguments.
        pass

    def reply(self, status, body):
        data = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.end_headers()
        self.wfile.write(data)

    def rpc(self, message, success=200):
        try:
            result = call_worker(self.server.worker_socket, message)
        except (OSError, ValueError):
            return self.reply(503, {'ok': False, 'code': 'worker_unavailable'})
        if result.get('ok'):
            if self.server.hide_tags and (self.server.hidden_tags or self.server.hidden_tag_fragments):
                filter_comic_tags(
                    result.get('data'), self.server.hidden_tags, self.server.hidden_tag_fragments
                )
            return self.reply(success, result)
        code = result.get('code')
        status = 404 if code == 'not_found' else 429 if code == 'queue_full' else 400
        self.reply(status, result)

    def authorized(self):
        value = self.headers.get('Authorization', '')
        if not hmac.compare_digest(value.encode(), ('Bearer ' + self.server.api_token).encode()):
            self.close_connection = True
            self.reply(401, {'ok': False, 'code': 'unauthorized'})
            return False
        # Reject browser origins; this endpoint is for authenticated tool clients.
        if self.headers.get('Origin'):
            self.close_connection = True
            self.reply(403, {'ok': False, 'code': 'origin_not_allowed'})
            return False
        return True

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == '/healthz':
            try:
                ready = call_worker(self.server.worker_socket, {'op': 'health'}, timeout=2).get('ok', False)
            except (OSError, ValueError):
                ready = False
            return self.reply(200 if ready else 503, {'ok': ready})
        if not self.authorized():
            return
        if path == '/v1/status':
            return self.rpc({'op': 'status'})
        if path == '/v1/requests':
            return self.rpc({'op': 'list'})
        if path.startswith('/v1/requests/') and path.count('/') == 3:
            return self.rpc({'op': 'get', 'id': path.rsplit('/', 1)[1]})
        self.reply(404, {'ok': False, 'code': 'not_found'})

    def do_POST(self):
        if not self.authorized():
            return
        # Refuse ambiguous/chunked bodies and cap allocations before parsing.
        if self.headers.get('Transfer-Encoding'):
            self.close_connection = True
            return self.reply(400, {'ok': False, 'code': 'invalid_body'})
        try:
            length = int(self.headers.get('Content-Length', '-1'))
            if length < 0 or length > MAX_BODY:
                self.close_connection = True
                return self.reply(413, {'ok': False, 'code': 'body_too_large'})
            body = json.loads(self.rfile.read(length))
            if not isinstance(body, dict):
                raise ValueError()
        except (ValueError, OSError):
            self.close_connection = True
            return self.reply(400, {'ok': False, 'code': 'invalid_json'})
        path = urlsplit(self.path).path
        if path == '/v1/commands':
            if set(body) - {'args'} or not isinstance(body.get('args'), list):
                return self.reply(400, {'ok': False, 'code': 'invalid_arguments'})
            return self.rpc({'op': 'submit', 'args': body['args']}, success=202)
        if path == '/v1/source-auth':
            if set(body) - {'sourceKey', 'action', 'credentials', 'replace', 'timeout', 'queueTimeout'}:
                return self.reply(400, {'ok': False, 'code': 'invalid_arguments'})
            return self.rpc({'op': 'source_auth', **body}, success=202)
        if path.startswith('/v1/requests/') and path.endswith('/cancel') and path.count('/') == 4:
            return self.rpc({'op': 'cancel', 'id': path.split('/')[3]})
        self.reply(404, {'ok': False, 'code': 'not_found'})

class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 32
    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(10)
        return connection, address

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--socket', default=os.environ.get('VENERA_WORKER_SOCKET', '/run/venera/worker.sock'))
    parser.add_argument('--host', default=os.environ.get('VENERA_API_HOST', '127.0.0.1'))
    parser.add_argument('--port', type=int, default=int(os.environ.get('VENERA_API_PORT', '8080')))
    parser.add_argument('--token-file', default=os.environ.get('VENERA_API_TOKEN_FILE', '/run/secrets/api_token'))
    parser.add_argument('--hide-tags', action=argparse.BooleanOptionalAction, default=None,
                        help='Enable tag filtering in HTTP comic results (default: disabled)')
    parser.add_argument('--hidden-tags', default=os.environ.get('VENERA_AI_HIDDEN_TAGS', '[]'),
                        help='JSON array of tags to omit from HTTP comic results')
    parser.add_argument('--hidden-tag-fragments',
                        default=os.environ.get('VENERA_AI_HIDDEN_TAG_FRAGMENTS', '[]'),
                        help='JSON array of substrings to match in HTTP comic tags')
    options = parser.parse_args()

    hide_tags = options.hide_tags
    if hide_tags is None:
        value = os.environ.get('VENERA_AI_HIDE_TAGS', 'false').strip().casefold()
        if value not in ('true', 'false', '1', '0'):
            parser.error('VENERA_AI_HIDE_TAGS must be true, false, 1 or 0')
        hide_tags = value in ('true', '1')

    def parse_tags(option, value):
        try:
            tags = json.loads(value)
            if not isinstance(tags, list) or any(
                not isinstance(tag, str) or not normalize_tag(tag) for tag in tags
            ):
                raise ValueError()
            return frozenset(normalize_tag(tag) for tag in tags)
        except ValueError:
            parser.error(f'{option} must be a JSON array of nonempty strings')

    hidden_tags = parse_tags('--hidden-tags', options.hidden_tags)
    hidden_fragments = parse_tags('--hidden-tag-fragments', options.hidden_tag_fragments)
    token = Path(options.token_file).read_text().strip()
    if len(token) < 32 or any(c.isspace() for c in token):
        parser.error('API token must contain at least 32 non-whitespace characters')
    server = Server((options.host, options.port), Gateway)
    server.worker_socket = options.socket
    server.api_token = token
    server.hide_tags = hide_tags
    server.hidden_tags = hidden_tags
    server.hidden_tag_fragments = hidden_fragments
    def stop(*_):
        threading.Thread(target=server.shutdown, daemon=True).start()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    print(json.dumps({'ready': True, 'port': server.server_port, 'pid': os.getpid()}), flush=True)
    try:
        server.serve_forever(poll_interval=0.2)
    finally:
        server.server_close()

if __name__ == '__main__':
    main()
