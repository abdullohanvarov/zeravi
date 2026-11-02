"""Loopback SSH/SFTP fixture. Requires asyncssh; never executes shell commands.
Start this script and pass its printed path as --dart-define=SSH_FIXTURE=<path>.
All keys and remote files are temporary and removed when the server stops.
"""
import asyncio
import json
import os
from pathlib import Path
import tempfile
import asyncssh

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
        async def shell(process):
            if process.command:
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
