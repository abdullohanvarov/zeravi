"""Parse a temporary generated unit with systemd; never installs/starts it."""
import subprocess
import sys
import tempfile
from pathlib import Path
from hosting_test_support import FakeServer, manager

with tempfile.TemporaryDirectory(prefix='zeravi unit ') as home:
    host = manager(home, FakeServer())
    root = Path(home) / 'bot-verify'
    python = root / 'current/venv/bin/python'
    python.parent.mkdir(parents=True)
    python.symlink_to(sys.executable)
    (root / 'current/app').mkdir()
    (root / 'environment').touch()
    unit = Path(home) / 'zeravi-bot-verify.service'
    unit.write_text(host.service_text('bot-verify', root, host.config({
        'name': 'Unit validation', 'arguments': ['literal $TOKEN 100%'],
    })))
    result = subprocess.run(['systemd-analyze', '--user', 'verify', str(unit)], capture_output=True, text=True)
    # Unrelated installed user-unit warnings are outside the generated unit.
    relevant = [line for line in result.stderr.splitlines() if str(unit) in line or 'zeravi-bot-verify.service:' in line]
    if result.returncode or relevant:
        raise SystemExit(result.stderr or 'Service syntax check failed')
    print('Generated user service passed systemd syntax validation (including paths with spaces).')
