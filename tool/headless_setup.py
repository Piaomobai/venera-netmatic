#!/usr/bin/env python3
"""Create a local API token without printing it or overwriting an existing key."""
import os
from pathlib import Path
import secrets

root = Path('.secrets')
if root.is_symlink():
    raise SystemExit('Refusing a symlinked secrets directory.')
root.mkdir(mode=0o700, exist_ok=True)
root.chmod(0o700)
target = root / 'api-token'
if target.is_symlink():
    raise SystemExit('Refusing a symlinked API token.')
try:
    descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
except FileExistsError:
    token = target.read_text().strip()
    if len(token) < 32 or any(c.isspace() for c in token):
        raise SystemExit('Existing API token is invalid; replace it manually.')
    target.chmod(0o444)
    print('Existing API token retained.')
else:
    with os.fdopen(descriptor, 'w') as stream:
        stream.write(secrets.token_hex(32) + '\n')
    # Compose file secrets are bind mounts: a non-root container must be able
    # to read the file. The parent remains 0700 to protect it on the host.
    target.chmod(0o444)
    print('API token created in .secrets/api-token (value not displayed).')
