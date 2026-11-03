"""Keep Xvfb alive until the Flutter worker has settled its writes on shutdown."""
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import time

children = []
worker = None
stopping_at = None

def stop(signum, _):
    global stopping_at
    if stopping_at is None:
        stopping_at = time.monotonic()
    if worker is not None and worker.poll() is None:
        worker.send_signal(signum)

def wait_socket(path, process):
    for _ in range(200):
        if process.poll() is not None:
            raise RuntimeError('A runtime dependency exited during startup')
        if Path(path).exists():
            return
        time.sleep(0.05)
    raise RuntimeError('Timed out starting virtual display/session bus')

def main():
    global worker
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    runtime = Path('/tmp/venera-runtime')
    runtime.mkdir(mode=0o700, exist_ok=True)
    runtime.chmod(0o700)
    # A killed container can leave socket/lock files in its writable layer.
    # Refuse a live helper, otherwise clear only our fixed private endpoints.
    for endpoint in ['/tmp/.X11-unix/X99', '/tmp/venera-session-bus']:
        if not Path(endpoint).exists():
            continue
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
            try:
                probe.connect(endpoint)
            except (ConnectionRefusedError, FileNotFoundError):
                Path(endpoint).unlink(missing_ok=True)
            else:
                raise RuntimeError('A virtual display/session bus is already running')
    Path('/tmp/.X99-lock').unlink(missing_ok=True)
    env = dict(os.environ, DISPLAY=':99', GDK_BACKEND='x11', LIBGL_ALWAYS_SOFTWARE='1',
               XDG_RUNTIME_DIR=str(runtime), NO_AT_BRIDGE='1',
               DBUS_SESSION_BUS_ADDRESS='unix:path=/tmp/venera-session-bus')
    try:
        display = subprocess.Popen(['Xvfb', ':99', '-screen', '0', '1280x720x24', '-nolisten', 'tcp', '-noreset'],
            stdin=subprocess.DEVNULL, stdout=sys.stderr, stderr=sys.stderr)
        children.append(display)
        wait_socket('/tmp/.X11-unix/X99', display)
        bus = subprocess.Popen(['dbus-daemon', '--session', '--nofork', '--nopidfile',
            '--address=unix:path=/tmp/venera-session-bus'], stdin=subprocess.DEVNULL,
            stdout=sys.stderr, stderr=sys.stderr)
        children.append(bus)
        wait_socket('/tmp/venera-session-bus', bus)
        executable = os.environ['VENERA_EXECUTABLE']
        args = sys.argv[1:]
        if args == ['--self-test']:
            command = ['python3', '/opt/venera/tests/headless_smoke_test.py', '--executable', executable, '--profile-root', '/tmp']
        elif args == ['--service-self-test']:
            command = ['python3', '/opt/venera/tests/headless_service_smoke.py', '--executable', executable,
                       '--profile-root', '/tmp', '--api-script', '/opt/venera/api_server.py']
        elif args == ['--auth-self-test']:
            command = ['python3', '/opt/venera/tests/headless_auth_smoke.py', '--executable', executable,
                       '--profile-root', '/tmp', '--api-script', '/opt/venera/api_server.py',
                       '--fixture', '/opt/venera/tests/headless_auth_source.js']
        else:
            command = [executable, '--headless', '--json', '--data-dir', os.environ.get('VENERA_DATA_DIR', '/data'), *args]
        worker = subprocess.Popen(command, env=env)
        if stopping_at is not None:
            worker.send_signal(signal.SIGTERM)
        grace = float(os.environ.get('VENERA_STOP_TIMEOUT', '90'))
        while worker.poll() is None:
            if stopping_at is not None and time.monotonic() - stopping_at > grace:
                print('Worker shutdown exceeded its grace period', file=sys.stderr)
                worker.kill()
            if any(child.poll() is not None for child in children):
                stop(signal.SIGTERM, None)
            time.sleep(0.1)
        return worker.returncode
    finally:
        if worker is not None and worker.poll() is None:
            worker.terminate()
            try:
                worker.wait(timeout=5)
            except subprocess.TimeoutExpired:
                worker.kill()
                worker.wait()
        for child in reversed(children):
            if child.poll() is None:
                child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()

if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print('Container startup failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
