"""Loopback SSH/SFTP fixture. Requires asyncssh; never executes shell commands.
Start this script and pass its printed path as --dart-define=SSH_FIXTURE=<path>.
All keys and remote files are temporary and removed when the server stops.
"""
import asyncio
import json
import os
from pathlib import Path
import tempfile
import time
import asyncssh
from hosting_test_support import FakeServer, manager

async def main():
    with tempfile.TemporaryDirectory(prefix='zeravi-ssh-') as temporary:
        root = Path(temporary)
        remote = root / 'remote'
        remote.mkdir()
        (remote / 'hello.txt').write_text('Hello from the test server!\n')
        (remote / 'binary.bin').write_bytes(b'\x00\x01\xff')
        (remote / 'folder').mkdir()
        host_key = asyncssh.generate_private_key('ssh-ed25519')
        client_key = asyncssh.generate_private_key('ssh-ed25519')
        key_path = root / 'client_key'
        key_path.write_bytes(client_key.export_private_key())
        os.chmod(key_path, 0o600)
        class Server(asyncssh.SSHServer):
            def begin_auth(self, username): return True
            def password_auth_supported(self): return True
            def validate_password(self, username, password):
                return username == 'tester' and password == 'zeravi-test-only'
            def public_key_auth_supported(self): return True
            def validate_public_key(self, username, key):
                return username == 'tester' and key == client_key.convert_to_public()
        hosting_runner = FakeServer()
        async def shell(process):
            if process.command:
                if 'zeravi-hosting' in process.command:
                    # This fixture invokes only the checked-in helper with fake OS
                    # commands; it never executes the client's shell command.
                    request = json.loads(await process.stdin.read())
                    if 'zipPath' in request:
                        request['zipPath'] = str(remote / Path(request['zipPath']).name)
                    def event(kind, **values):
                        process.stdout.write(json.dumps(dict(event=kind, **values)) + '\n')
                    try:
                        result = manager(remote, hosting_runner, event).handle(request)
                        event('result', data=result)
                    except Exception as error:
                        event('error', message=str(error))
                elif '__Z_HOST__' in process.command:
                    ticks = int(time.monotonic() * 100)
                    process.stdout.write(f'''__Z_HOST__
zeravi-fixture
Linux 6.8.0-test
__Z_CPU__
cpu {ticks * 3} 0 100 {ticks * 7} 0 0 0 0 0 0
__Z_MEM__
MemTotal: 4194304 kB
MemAvailable: 2621440 kB
SwapTotal: 1048576 kB
SwapFree: 917504 kB
__Z_LOAD__
0.30 0.20 0.10 1/100 200
__Z_UPTIME__
86460.00 1000.00
__Z_NET__
Inter-| Receive | Transmit
 face |bytes packets errs drop fifo frame compressed multicast|bytes packets errs drop fifo colls carrier compressed
eth0: {ticks * 2048} 1 0 0 0 0 0 0 {ticks * 1024} 1 0 0 0 0 0 0
__Z_ROUTE__
Iface Destination Gateway Flags RefCnt Use Metric Mask
eth0 00000000 0100000A 0003 0 0 100 00000000
__Z_DISK__
Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/vda1 20971520 8388608 12582912 40% /
__Z_PS__
PID %CPU %MEM COMMAND
101 12.3 4.2 python3
102 3.1 1.4 node
__Z_END__
''')
                else:
                    process.stdout.write('command ok\n')
                process.exit(0)
                return
            process.stdout.write('Zeravi test shell ready\r\n')
            while True:
                try:
                    line = await process.stdin.readline()
                except asyncssh.TerminalSizeChanged:
                    continue
                if not line or line.strip() == 'exit': break
                process.stdout.write('echo: ' + line)
            process.exit(0)
        server = await asyncssh.create_server(
            Server, '127.0.0.1', 0, server_host_keys=[host_key],
            process_factory=shell,
            sftp_factory=lambda channel: asyncssh.SFTPServer(channel, chroot=str(remote)))
        fixture = root / 'fixture.json'
        fixture.write_text(json.dumps({'port': server.get_port(), 'keyPath': str(key_path),
            'root': str(remote), 'fingerprint': host_key.get_fingerprint()}))
        print(str(fixture), flush=True)
        try: await asyncio.Future()
        finally:
            server.close()
            await server.wait_closed()
try: asyncio.run(main())
except KeyboardInterrupt: pass
