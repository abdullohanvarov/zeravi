"""Zeravi's remote Python hosting protocol. Requests arrive on stdin, not argv.

Only named Zeravi user services and application-owned directories are managed.
All commands use argv arrays. This module can be imported with a fake runner in
unit tests; importing it never touches services or the filesystem.
"""
import contextlib
import datetime
import fcntl
import getpass
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import signal
import stat
import subprocess
import sys
import time
import uuid
import zipfile

MAX_ZIP = 100 * 1024 * 1024
MAX_EXPANDED = 1024 * 1024 * 1024
MAX_FILES = 10000
IGNORED = {'.git', '.venv', 'venv', '__pycache__', '__MACOSX', '.DS_Store'}
ID = re.compile(r'[a-z0-9][a-z0-9-]{2,63}\Z')
RELEASE = re.compile(r'r-[0-9]{14}-[a-f0-9]{8}\Z')


class HostingError(Exception):
    pass


def relative(value, allow_empty=False):
    if not isinstance(value, str) or '\\' in value or '\0' in value or '\n' in value or '\r' in value:
        raise HostingError('Invalid project path.')
    if value == '' and allow_empty:
        return ''
    parts = value.split('/')
    if not value or value.startswith('/') or re.match(r'^[A-Za-z]:', value) or any(p in ('', '.', '..') for p in parts):
        raise HostingError('Project paths must stay inside the project folder.')
    if len(value.encode()) > 4096 or any(len(p.encode()) > 255 for p in parts):
        raise HostingError('A project path is too long.')
    return '/'.join(parts)


def private_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_name(path.name + '.tmp-' + uuid.uuid4().hex)
    try:
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as handle:
            json.dump(value, handle, ensure_ascii=False)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def unit_quote(value, exec_arg=False):
    if any(c in str(value) for c in '\0\r\n'):
        raise HostingError('Service settings cannot contain line breaks.')
    text = str(value).replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%')
    if exec_arg:
        text = text.replace('$', '$$')
    return '"' + text + '"'


def environment_values(value):
    if not isinstance(value, dict) or len(value) > 100:
        raise HostingError('Use at most 100 environment variables.')
    result = {}
    for key, item in value.items():
        if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', key) or not isinstance(item, str) or any(c in item for c in '\0\r\n'):
            raise HostingError('Environment variables must use NAME=value on one line.')
        if len(item.encode()) > 16384:
            raise HostingError('An environment variable is too large.')
        result[key] = item
    return result


def redact(text, values):
    for value in sorted(values, key=len, reverse=True):
        if len(value) >= 4:
            text = text.replace(value, '[redacted]')
    return re.sub(r'(https?://)[^\s/@:]+:[^\s/@]+@', r'\1[redacted]@', text)


def inspect_zip(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_ZIP:
        raise HostingError('Choose a regular ZIP file up to 100 MiB.')
    entries = []
    names = set()
    total = 0
    with zipfile.ZipFile(path) as archive:
        infos = archive.infolist()
        if len(infos) > MAX_FILES:
            raise HostingError('The ZIP has more than 10,000 entries.')
        for info in infos:
            name = relative(info.orig_filename.rstrip('/'))
            if name in names:
                raise HostingError('The ZIP contains duplicate paths.')
            names.add(name)
            mode = info.external_attr >> 16
            kind = stat.S_IFMT(mode)
            if info.flag_bits & 1 or kind not in (0, stat.S_IFREG, stat.S_IFDIR):
                raise HostingError('Encrypted ZIPs, symbolic links and special files are not supported.')
            total += info.file_size
            if total > MAX_EXPANDED or info.file_size > 256 * 1024 * 1024:
                raise HostingError('The extracted project is too large (limit 1 GiB, 256 MiB per file).')
            if not any(part in IGNORED for part in PurePosixPath(name).parts):
                entries.append((info, name))
        files = {name for info, name in entries if not info.is_dir()}
        for name in files:
            parent = PurePosixPath(name).parent
            while str(parent) != '.':
                if str(parent) in files:
                    raise HostingError('A ZIP path is both a file and a folder.')
                parent = parent.parent
        roots = sorted({str(PurePosixPath(name).parent) for name in files if PurePosixPath(name).name == 'requirements.txt'})
        roots = ['' if root == '.' else root for root in roots]
    if not roots:
        raise HostingError('The ZIP must contain requirements.txt in the project folder.')
    return entries, roots


def extract_project(archive_path, destination, project_root, entrypoint):
    entries, roots = inspect_zip(archive_path)
    project_root = relative(project_root, allow_empty=True)
    entrypoint = relative(entrypoint)
    if project_root not in roots or not entrypoint.endswith('.py'):
        raise HostingError('Choose a folder containing requirements.txt and a Python entry point.')
    prefix = project_root + '/' if project_root else ''
    selected = [(info, name[len(prefix):]) for info, name in entries if name.startswith(prefix) and name != project_root]
    files = {name for info, name in selected if not info.is_dir()}
    if 'requirements.txt' not in files or entrypoint not in files:
        raise HostingError('The selected project does not contain requirements.txt and the entry-point file.')
    destination.mkdir(mode=0o700, parents=True)
    expanded = 0
    with zipfile.ZipFile(archive_path) as archive:
        for info, name in selected:
            target = destination / relative(name)
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            if info.is_dir():
                target.mkdir(mode=0o700, exist_ok=True)
                continue
            with archive.open(info) as source, target.open('xb') as output:
                count = 0
                while True:
                    chunk = source.read(64 * 1024)
                    if not chunk:
                        break
                    count += len(chunk)
                    expanded += len(chunk)
                    if count > 256 * 1024 * 1024 or expanded > MAX_EXPANDED:
                        raise HostingError('ZIP expansion exceeded the size limit.')
                    output.write(chunk)
            target.chmod(0o600)


class HostingManager:
    def __init__(self, home=None, runner=None, event=None):
        self.home = Path(home or Path.home()).resolve()
        self.base = self.home / 'telegrambots'
        self.legacy_base = self.home / '.local/share/zeravi/bots'
        self.units = self.home / '.config/systemd/user'
        self.runner = runner
        self.event = event or (lambda kind, **data: None)
        self.secrets = []
        self.env = dict(os.environ)
        runtime = '/run/user/' + str(os.getuid())
        self.env.setdefault('XDG_RUNTIME_DIR', runtime)
        self.env.setdefault('DBUS_SESSION_BUS_ADDRESS', 'unix:path=' + runtime + '/bus')

    def command(self, args, check=True, timeout=25, stream=False, cwd=None):
        if self.runner:
            result = self.runner(args, timeout=timeout, stream=stream, cwd=cwd)
        elif stream:
            # Packages run only on this SSH server, inside the new release's venv.
            process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                       stdin=subprocess.DEVNULL, env=self.env, cwd=cwd, start_new_session=True)
            import selectors
            selector = selectors.DefaultSelector()
            selector.register(process.stdout, selectors.EVENT_READ)
            chunks = []
            deadline = time.monotonic() + timeout
            import codecs
            decoder = codecs.getincrementaldecoder('utf-8')('replace')
            pending = ''
            os.set_blocking(process.stdout.fileno(), False)
            try:
                while True:
                    if time.monotonic() > deadline:
                        raise HostingError('Dependency installation timed out. The previous release is unchanged.')
                    ready = selector.select(timeout=1)
                    if ready:
                        data = os.read(process.stdout.fileno(), 16384)
                        if not data:
                            break
                        pending += decoder.decode(data)
                        while '\n' in pending or len(pending) > 16384:
                            if '\n' in pending:
                                line, pending = pending.split('\n', 1)
                            else:
                                line, pending = pending[:16384], pending[16384:]
                            line = redact(line.rstrip(), self.secrets)
                            self.event('log', message=line)
                            chunks.append(line)
                            if len(chunks) > 100:
                                chunks.pop(0)
                    elif process.poll() is not None:
                        continue
                pending += decoder.decode(b'', final=True)
                if pending:
                    line = redact(pending, self.secrets)
                    self.event('log', message=line)
                    chunks.append(line)
                result = subprocess.CompletedProcess(args, process.wait(timeout=10), '\n'.join(chunks), '')
            except BaseException:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGTERM)
                with contextlib.suppress(subprocess.TimeoutExpired):
                    process.wait(timeout=5)
                if process.poll() is None:
                    with contextlib.suppress(ProcessLookupError):
                        os.killpg(process.pid, signal.SIGKILL)
                raise
            finally:
                selector.close()
                process.stdout.close()
        else:
            result = subprocess.run(args, capture_output=True, text=True, errors='replace', env=self.env,
                                    stdin=subprocess.DEVNULL, cwd=cwd, timeout=timeout)
        if check and result.returncode:
            detail = redact(((result.stderr or '') + '\n' + (result.stdout or '')).strip(), self.secrets)[-2500:]
            raise HostingError(f'{Path(args[0]).name} failed: {detail or "command exited unsuccessfully"}')
        return result

    def systemctl(self, *args, **kwargs):
        return self.command(['systemctl', '--user', *args], **kwargs)

    def doctor(self):
        manager = self.systemctl('show-environment', check=False)
        linger = self.command(['loginctl', 'show-user', str(os.getuid()), '--property=Linger', '--value'], check=False)
        supported = sys.version_info >= (3, 9)
        venv = importlib.util.find_spec('venv') is not None and importlib.util.find_spec('ensurepip') is not None
        return dict(python=sys.version.split()[0], pythonSupported=supported, venv=venv, userManager=manager.returncode == 0,
                    linger=linger.returncode == 0 and linger.stdout.strip() == 'yes', username=getpass.getuser(),
                    ready=supported and venv and manager.returncode == 0 and linger.stdout.strip() == 'yes',
                    root=self.base.as_posix())

    @contextlib.contextmanager
    def lock(self):
        self.base.mkdir(parents=True, exist_ok=True, mode=0o700)
        if self.base.is_symlink():
            raise HostingError('The hosting directory must not be a symbolic link.')
        fd = os.open(self.base / '.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise HostingError('Another bot operation is running. Wait for it to finish.')
            yield
        finally:
            os.close(fd)

    def prepare_storage(self):
        # Keep old absolute venv shebangs, data links and service paths working.
        # Projects move physically; private compatibility links stay at old paths.
        if self.base.is_symlink():
            raise HostingError('The telegrambots directory must not be a symbolic link.')
        self.base.mkdir(parents=True, exist_ok=True, mode=0o700)
        legacy = self.legacy_base
        if legacy.is_symlink():
            if legacy.resolve() == self.base.resolve():
                return
            raise HostingError('The old bot storage is a symbolic link. Move it manually before continuing.')
        if not legacy.exists():
            return
        fd = os.open(legacy / '.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise HostingError('An older bot operation is running. Wait for it to finish, then refresh.')
            with self.lock():
                pending = []
                for source in sorted(legacy.iterdir()):
                    if source.name == '.lock':
                        continue
                    target = self.base / source.name
                    if source.is_symlink() and source.readlink() == target and not target.is_symlink():
                        if not target.exists():
                            source.unlink()  # Clean compatibility links after removal.
                            continue
                        if target.is_dir():
                            continue
                    if source.is_symlink() or not source.is_dir() or not (ID.fullmatch(source.name) or source.name == '_archives'):
                        raise HostingError('Unexpected files in the old bot directory; move them aside before migration.')
                    if target.exists() or target.is_symlink():
                        raise HostingError('Cannot migrate ' + source.name + ': that name already exists in ~/telegrambots. No files were overwritten.')
                    pending.append((source, target))
                for source, target in pending:
                    source.rename(target)
                    try:
                        source.symlink_to(target, target_is_directory=True)
                    except BaseException:
                        target.rename(source)
                        raise
                    self.event('progress', message='Moved ' + source.name + ' into ~/telegrambots')
        finally:
            os.close(fd)

    def bot_root(self, bot_id, required=True):
        if not isinstance(bot_id, str) or not ID.fullmatch(bot_id):
            raise HostingError('Invalid managed bot identifier.')
        root = self.base / bot_id
        if self.base.is_symlink() or root.is_symlink() or any((root / name).is_symlink() for name in ('releases', 'shared', 'manifest.json', 'config.json')):
            raise HostingError('Managed hosting directories must not be replaced by symbolic links.')
        if required:
            manifest = root / 'manifest.json'
            if not manifest.is_file() or self.load(manifest).get('id') != bot_id:
                raise HostingError('This bot is not managed by Zeravi.')
        return root

    def load(self, path, default=None):
        if not path.exists() and default is not None:
            return default
        with path.open() as handle:
            return json.load(handle)

    def status(self, bot_id):
        root = self.bot_root(bot_id)
        manifest = self.load(root / 'manifest.json')
        result = self.systemctl('show', 'zeravi-bot-' + bot_id + '.service', '--property=ActiveState,SubState,MainPID,NRestarts,MemoryCurrent,ExecMainStatus,Result', check=False)
        state = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
        config = self.load(root / 'config.json', {})
        return dict(id=bot_id, name=manifest['name'], entrypoint=manifest['entrypoint'], current=manifest['current'],
                    previous=manifest.get('previous'), updated=manifest['updated'], path=str(root / 'current/app'),
                    autostart=config.get('autostart', True), restart=config.get('restart', 'on-failure'),
                    persistent=config.get('persistent', ['data', 'uploads', 'storage']), envKeys=sorted(config.get('environment', {})),
                    state=state.get('ActiveState', 'unknown'), subState=state.get('SubState', ''),
                    pid=state.get('MainPID', '0'), restarts=state.get('NRestarts', '0'), memory=state.get('MemoryCurrent', ''),
                    exitStatus=state.get('ExecMainStatus', ''), result=state.get('Result', ''), warning=manifest.get('warning', ''))

    def listing(self):
        bots = []
        if self.base.exists():
            for root in sorted(self.base.iterdir()):
                if root.is_dir() and not root.is_symlink() and ID.fullmatch(root.name) and (root / 'manifest.json').is_file():
                    bots.append(self.status(root.name))
        return dict(doctor=self.doctor(), bots=bots)

    def config(self, request, existing=None):
        existing = existing or {}
        name = request.get('name', existing.get('name', 'Python bot')).strip()
        if not name or len(name) > 80 or any(c in name for c in '\r\n\0'):
            raise HostingError('Use a bot name from 1 to 80 characters.')
        entrypoint = relative(request.get('entrypoint', existing.get('entrypoint', 'main.py')))
        if not entrypoint.endswith('.py'):
            raise HostingError('Choose a Python .py entry-point file.')
        restart = request.get('restart', existing.get('restart', 'on-failure'))
        if restart not in ('on-failure', 'always', 'no'):
            raise HostingError('Choose a supported restart policy.')
        args = request.get('arguments', existing.get('arguments', []))
        if not isinstance(args, list) or len(args) > 50 or any(not isinstance(a, str) or any(c in a for c in '\0\r\n') or len(a) > 4096 for a in args):
            raise HostingError('Use at most 50 arguments, one per line.')
        persistent = request.get('persistent', existing.get('persistent', ['data', 'uploads', 'storage']))
        if not isinstance(persistent, list) or len(persistent) > 30:
            raise HostingError('Use at most 30 persistent paths.')
        persistent = list(dict.fromkeys(relative(item) for item in persistent))
        for path in persistent:
            if '/' in path:
                raise HostingError('Persistent paths must be top-level files or folders, such as data or bot.db.')
            if path == 'requirements.txt' or path.endswith('.py'):
                raise HostingError('Persistent paths must be data, not Python code or requirements.txt.')
            if any(path.startswith(other + '/') for other in persistent if other != path):
                raise HostingError('Persistent paths cannot overlap.')
        environment = environment_values(existing.get('environment', {}))
        for key in request.get('removeEnv', []):
            environment.pop(key, None)
        environment.update(environment_values(request.get('environment', {})))
        self.secrets = list(environment.values())
        return dict(name=name, entrypoint=entrypoint, restart=restart, arguments=args, persistent=persistent,
                    environment=environment, autostart=bool(request.get('autostart', existing.get('autostart', True))))

    def write_config(self, root, config):
        private_json(root / 'config.json', config)
        lines = []
        for key, value in config['environment'].items():
            lines.append(key + '="' + value.replace('\\', '\\\\').replace('"', '\\"') + '"')
        temporary = root / ('env.tmp-' + uuid.uuid4().hex)
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as handle:
            handle.write('\n'.join(lines) + '\n')
        os.replace(temporary, root / 'environment')

    def service_text(self, bot_id, root, config):
        unit_quote(root)
        args = [str(root / 'current/venv/bin/python'), '-u', str(root / 'current/app' / config['entrypoint']), *config['arguments']]
        return f'''# Managed by Zeravi bot {bot_id}
[Unit]
Description=Zeravi Python bot {bot_id}
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
WorkingDirectory={str(root / 'current/app').replace('%', '%%')}
ExecStart={' '.join(unit_quote(arg, exec_arg=True) for arg in args)}
EnvironmentFile={str(root / 'environment').replace('%', '%%')}
Environment=PYTHONUNBUFFERED=1
Environment={unit_quote('ZERAVI_DATA_DIR=' + str(root / 'shared'))}
Restart={config['restart']}
RestartSec=5
TimeoutStopSec=20
KillMode=control-group
UMask=0077
NoNewPrivileges=true
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
'''

    def owned_unit(self, bot_id, required=True):
        path = self.units / ('zeravi-bot-' + bot_id + '.service')
        if path.is_symlink() or self.units.is_symlink():
            raise HostingError('The managed service must not be a symbolic link.')
        if path.exists():
            if not path.read_text().startswith('# Managed by Zeravi bot ' + bot_id + '\n'):
                raise HostingError('A different service already uses this managed name.')
        elif required:
            raise HostingError('The service file is missing. Update the project ZIP to repair it.')
        return path

    def write_service(self, bot_id, root, config):
        self.units.mkdir(parents=True, exist_ok=True, mode=0o700)
        path = self.owned_unit(bot_id, required=False)
        temporary = path.with_suffix('.tmp-' + uuid.uuid4().hex)
        temporary.write_text(self.service_text(bot_id, root, config))
        temporary.chmod(0o600)
        os.replace(temporary, path)
        self.systemctl('daemon-reload')
        self.systemctl('enable' if config['autostart'] else 'disable', path.name)

    def release_path(self, root, version):
        if not isinstance(version, str) or not RELEASE.fullmatch(version):
            raise HostingError('Invalid release identifier.')
        path = root / 'releases' / version
        if (root / 'releases').is_symlink() or path.is_symlink() or not path.is_dir() or (path / 'app').is_symlink():
            raise HostingError('The release is missing or is a symbolic link.')
        return path

    def switch(self, root, version):
        self.release_path(root, version)
        link = root / ('.current-' + uuid.uuid4().hex)
        link.symlink_to(Path('releases') / version, target_is_directory=True)
        os.replace(link, root / 'current')

    def persistent_data(self, root, release, previous, paths):
        shared = root / 'shared'
        if shared.is_symlink():
            raise HostingError('The persistent data directory must not be a symbolic link.')
        shared.mkdir(mode=0o700, exist_ok=True)
        for name in paths:
            target = shared / name
            current = release / 'app' / name
            before = previous / 'app' / name if previous else None
            for candidate in (target, before, current):
                if candidate is not None and candidate.is_symlink():
                    if candidate == target or not candidate.resolve().is_relative_to(shared.resolve()):
                        raise HostingError('A persistent path contains an unsupported symbolic link.')
            if not target.exists():
                source = before if before is not None and before.exists() else current if current.exists() else None
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                if source and source.is_dir():
                    for parent, directories, files in os.walk(source, followlinks=False):
                        if any((Path(parent) / name).is_symlink() for name in directories + files):
                            raise HostingError('Persistent data cannot contain symbolic links.')
                    shutil.copytree(source, target, symlinks=False)
                elif source:
                    shutil.copy2(source, target)
                    target.chmod(0o600)
                elif not PurePosixPath(name).suffix:
                    target.mkdir(mode=0o700)
                else:
                    continue
            current.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            if current.is_symlink():
                current.unlink()
            elif current.is_dir():
                shutil.rmtree(current)
            elif current.exists():
                current.unlink()
            current.symlink_to(target, target_is_directory=target.is_dir())

    def deploy(self, request):
        readiness = self.doctor()
        if not readiness['ready']:
            raise HostingError('Server setup is incomplete. Install Python 3.9+ with python3-venv, enable user services, and enable linger before hosting a bot.')
        bot_id = request.get('id') or 'bot-' + uuid.uuid4().hex[:12]
        root = self.bot_root(bot_id, required=bool(request.get('id')))
        if not request.get('id') and root.exists():
            raise HostingError('That bot identifier is already in use.')
        old = self.load(root / 'manifest.json', {}) if root.exists() else {}
        old_config = self.load(root / 'config.json', {}) if root.exists() else {}
        config = self.config(request, old_config)
        self.owned_unit(bot_id, required=False)
        upload = Path(request.get('zipPath', ''))
        if upload.parent.resolve() != self.home or not upload.name.startswith('.zeravi-upload-') or upload.is_symlink():
            raise HostingError('Use a ZIP uploaded by Zeravi into this account.')
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
        version = 'r-' + datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%d%H%M%S') + '-' + uuid.uuid4().hex[:8]
        release = root / 'releases' / version
        switched = False
        previous = self.release_path(root, old['current']) if old else None
        stopped_previous = False
        was_running = self.status(bot_id)['state'] in ('active', 'activating') if old else False
        try:
            self.event('progress', message='Validating and extracting the project')
            extract_project(upload, release / 'app', request.get('projectRoot', ''), config['entrypoint'])
            self.event('progress', message='Creating an isolated Python environment')
            self.command([sys.executable, '-m', 'venv', str(release / 'venv')], timeout=120)
            self.event('progress', message='Installing requirements.txt')
            self.command([str(release / 'venv/bin/python'), '-m', 'pip', 'install', '--disable-pip-version-check', '--no-input', '-r', str(release / 'app/requirements.txt')], timeout=900, stream=True, cwd=str(release / 'app'))
            private_json(release / 'release.json', dict(entrypoint=config['entrypoint'], created=version))
            if old:
                self.event('progress', message='Stopping the previous release for the update')
                self.systemctl('stop', 'zeravi-bot-' + bot_id + '.service')
                stopped_previous = True
            self.persistent_data(root, release, previous, config['persistent'])
            self.write_config(root, config)
            self.switch(root, version)
            switched = True
            self.write_service(bot_id, root, config)
            manifest = dict(id=bot_id, name=config['name'], entrypoint=config['entrypoint'], current=version,
                            previous=old.get('current'), updated=datetime.datetime.now(datetime.timezone.utc).isoformat())
            private_json(root / 'manifest.json', manifest)
            if request.get('start', True):
                self.event('progress', message='Starting the bot service')
                self.systemctl('reset-failed', 'zeravi-bot-' + bot_id + '.service', check=False)
                start = self.systemctl('start', 'zeravi-bot-' + bot_id + '.service', check=False)
                if start.returncode:
                    if old:
                        raise HostingError('The updated service did not start. Restoring the previous release.')
                    manifest['warning'] = 'The project is deployed but its service could not start. Open logs and check its configuration.'
                    private_json(root / 'manifest.json', manifest)
            self.event('progress', message='Deployment complete')
            return self.status(bot_id)
        except BaseException:
            if switched and old:
                self.systemctl('stop', 'zeravi-bot-' + bot_id + '.service', check=False)
                self.switch(root, old['current'])
                self.write_config(root, old_config)
                self.write_service(bot_id, root, old_config)
                private_json(root / 'manifest.json', old)
                if was_running:
                    self.systemctl('start', 'zeravi-bot-' + bot_id + '.service', check=False)
            if stopped_previous and not switched and old:
                self.write_config(root, old_config)
                self.write_service(bot_id, root, old_config)
                if was_running:
                    self.systemctl('start', 'zeravi-bot-' + bot_id + '.service', check=False)
            if not old:
                unit = self.owned_unit(bot_id, required=False)
                if unit.exists():
                    self.systemctl('stop', unit.name, check=False)
                    self.systemctl('disable', unit.name, check=False)
                    unit.unlink()
                    self.systemctl('daemon-reload', check=False)
                shutil.rmtree(root, ignore_errors=True)
            elif not switched:
                shutil.rmtree(release, ignore_errors=True)
            raise
        finally:
            upload.unlink(missing_ok=True)

    def restore(self, bot_id, root, manifest, config, running):
        self.systemctl('stop', 'zeravi-bot-' + bot_id + '.service', check=False)
        self.switch(root, manifest['current'])
        self.persistent_data(root, self.release_path(root, manifest['current']), None, config['persistent'])
        self.write_config(root, config)
        self.write_service(bot_id, root, config)
        private_json(root / 'manifest.json', manifest)
        if running:
            self.systemctl('start', 'zeravi-bot-' + bot_id + '.service', check=False)

    def detach_paths(self, root, release, paths):
        for name in paths:
            path = release / 'app' / name
            if path.is_symlink() and path.resolve().is_relative_to((root / 'shared').resolve()):
                path.unlink()

    def configure(self, request):
        bot_id = request['id']
        root = self.bot_root(bot_id)
        self.owned_unit(bot_id)
        manifest = self.load(root / 'manifest.json')
        old_config = self.load(root / 'config.json')
        config = self.config(request, old_config)
        release = self.release_path(root, manifest['current'])
        if not (release / 'app' / config['entrypoint']).is_file():
            raise HostingError('That entry point is not in the deployed project.')
        running = self.status(bot_id)['state'] in ('active', 'activating')
        self.systemctl('stop', 'zeravi-bot-' + bot_id + '.service')
        try:
            self.persistent_data(root, release, None, config['persistent'])
            self.detach_paths(root, release, set(old_config['persistent']) - set(config['persistent']))
            self.write_config(root, config)
            self.write_service(bot_id, root, config)
            updated = dict(manifest, name=config['name'], entrypoint=config['entrypoint'], warning='')
            private_json(root / 'manifest.json', updated)
            if request.get('start', True):
                self.systemctl('reset-failed', 'zeravi-bot-' + bot_id + '.service', check=False)
                self.systemctl('start', 'zeravi-bot-' + bot_id + '.service')
            return self.status(bot_id)
        except BaseException:
            self.detach_paths(root, release, set(config['persistent']) - set(old_config['persistent']))
            self.restore(bot_id, root, manifest, old_config, running)
            raise

    def rollback(self, request):
        bot_id = request['id']
        root = self.bot_root(bot_id)
        self.owned_unit(bot_id)
        manifest = self.load(root / 'manifest.json')
        version = manifest.get('previous')
        if not version:
            raise HostingError('There is no previous release to restore.')
        previous = self.release_path(root, version)
        current = self.release_path(root, manifest['current'])
        old_config = self.load(root / 'config.json')
        config = dict(old_config, entrypoint=self.load(previous / 'release.json')['entrypoint'])
        running = self.status(bot_id)['state'] in ('active', 'activating')
        self.systemctl('stop', 'zeravi-bot-' + bot_id + '.service')
        try:
            self.persistent_data(root, previous, current, config['persistent'])
            self.switch(root, version)
            self.write_config(root, config)
            self.write_service(bot_id, root, config)
            updated = dict(manifest, current=version, previous=manifest['current'], entrypoint=config['entrypoint'], warning='')
            private_json(root / 'manifest.json', updated)
            self.systemctl('reset-failed', 'zeravi-bot-' + bot_id + '.service', check=False)
            self.systemctl('start', 'zeravi-bot-' + bot_id + '.service')
            return self.status(bot_id)
        except BaseException:
            self.restore(bot_id, root, manifest, old_config, running)
            raise

    def control(self, request):
        bot_id = request['id']
        self.bot_root(bot_id)
        self.owned_unit(bot_id)
        verb = request['verb']
        if verb not in ('start', 'stop', 'restart'):
            raise HostingError('Unsupported service action.')
        if verb != 'stop':
            self.systemctl('reset-failed', 'zeravi-bot-' + bot_id + '.service', check=False)
        self.systemctl(verb, 'zeravi-bot-' + bot_id + '.service')
        return self.status(bot_id)

    def logs(self, request):
        bot_id = request['id']
        root = self.bot_root(bot_id)
        config = self.load(root / 'config.json')
        self.secrets = list(config.get('environment', {}).values())
        result = self.command(['journalctl', '--user', '--unit=zeravi-bot-' + bot_id + '.service', '--no-pager', '--output=short-iso', '-n', '200'], check=False)
        return dict(text=redact(result.stdout[-100000:], self.secrets), available=result.returncode == 0)

    def remove(self, request):
        bot_id = request['id']
        root = self.bot_root(bot_id)
        unit = self.owned_unit(bot_id, required=False)
        if unit.exists():
            self.systemctl('stop', unit.name)
            self.systemctl('disable', unit.name)
            unit.unlink()
        self.systemctl('daemon-reload')
        archive = None
        if request.get('deleteData', False):
            shutil.rmtree(root)
        else:
            archives = self.base / '_archives'
            if archives.is_symlink():
                raise HostingError('The archive directory must not be a symbolic link.')
            archives.mkdir(mode=0o700, exist_ok=True)
            archive = str(archives / (bot_id + '-' + uuid.uuid4().hex[:8]))
            root.rename(archive)
        return dict(removed=True, archive=archive)

    def handle(self, request):
        self.prepare_storage()
        action = request.get('action')
        if action == 'list':
            return self.listing()
        if action == 'logs':
            return self.logs(request)
        handlers = dict(deploy=self.deploy, configure=self.configure, rollback=self.rollback, control=self.control, remove=self.remove)
        if action not in handlers:
            raise HostingError('Unknown hosting action.')
        with self.lock():
            return handlers[action](request)


def main():
    manager = None
    def event(kind, **data):
        print(json.dumps(dict(event=kind, **data), ensure_ascii=False), flush=True)
    try:
        raw = sys.stdin.read(256 * 1024 + 1)
        if len(raw) > 256 * 1024:
            raise HostingError('Hosting request is too large.')
        manager = HostingManager(event=event)
        result = manager.handle(json.loads(raw))
        event('result', data=result)
    except Exception as error:
        message = redact(str(error), manager.secrets if manager else [])
        event('error', message=message or type(error).__name__)
        sys.exit(1)


if __name__ == '__main__':
    main()
