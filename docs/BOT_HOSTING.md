# Python Telegram bot hosting

Connect to a Linux VPS, open **Bots**, and choose **Deploy ZIP**. Zeravi uploads
the archive over SFTP, creates a separate Python virtual environment on the VPS,
installs `requirements.txt`, and runs the selected Python file as a systemd user
service. Dependencies and project code execute on the VPS, never on your PC.

## Prepare the server once

Use Python 3.9 or newer and a dedicated SSH account with a home directory and write access. Ubuntu /
Debian servers normally need:

```sh
sudo apt-get install python3 python3-venv
sudo loginctl enable-linger YOUR_SSH_USERNAME
```

Reconnect afterward. **Server setup** shows commands using the connected user
and offers a terminal. The readiness badges check Python, the `venv`/`ensurepip`
modules, a reachable systemd user manager, and linger. Zeravi does not run sudo
or change login settings automatically. Other distributions need equivalent
packages. Servers/containers without a working systemd user session are unsupported.

Linger permits user services to run after logout and start during boot. Keep
**Start automatically after reboot** enabled for boot startup. Turning it off
only disables boot startup; it does not stop a currently running bot.

## Prepare and deploy a ZIP

A typical archive is:

```text
my-bot/
  requirements.txt
  main.py
  handlers/
  data/
```

- Include `requirements.txt`, even if it is empty. Pin versions for reproducible
  deployments; native Python packages may need additional VPS system packages.
- Exclude your existing virtual environment, Git history, caches, and credentials.
  `.git`, `.venv`, `venv`, `__pycache__`, and macOS metadata are ignored.
- Select the folder containing `requirements.txt`, then the Python entry point.
  `main.py`, `bot.py`, and `app.py` are suggested when present. Nested scripts work.
- Enter environment variables as `NAME=value`, one per line. Use the eye button
  to open the multiline editor. In Python, read a token with
  `os.environ["BOT_TOKEN"]`; Zeravi does not rewrite your code or create `.env`.
- Choose crash restart behavior, boot startup, persistent paths, optional
  command arguments, and whether to start immediately.

Limits are 100 MiB per ZIP, 10,000 archive entries, 1 GiB extracted total, and
256 MiB per file. Encrypted archives, symlinks, special files, duplicate names,
and unsafe/traversing paths are rejected. Inspection on the PC reads ZIP metadata;
the VPS independently validates it and checks file contents during extraction.
Do not deploy untrusted projects or dependencies: installation can execute code
as your SSH user. This is process management, not isolation between hostile apps.

Deployment activity shows upload, extraction, virtual environment creation,
dependency installation, and service startup. Dependency installation has a
15-minute limit. Build failures leave an existing bot running. Update activation
briefly stops that bot; a failed service start restores the previous code and
configuration when possible. A process that starts successfully and crashes later
is shown as failed/restarting; inspect its logs and use rollback if needed.

## Manage bots

Each card shows process state, PID, current RAM, automatic restart count, boot
setting, and the last deployment time. Status refreshes every eight seconds
while Bots is visible.

- **Start / Stop / Restart** controls the service, independently of the SSH shell.
- **Logs** shows the latest 200 user-journal lines, with automatic refresh, a
  local text filter, and copy. Journal access must be available for the SSH user.
- **Update ZIP** creates a fresh release and virtual environment. Existing
  environment values and command arguments are kept unless explicitly replaced.
- **Settings & environment** changes the name, entry point, variables, restart
  policy, persistent paths and startup settings. Existing values are never sent
  back to the app; key names are displayed. Blank input keeps stored values;
  the remove-keys field explicitly removes them. Saving briefly stops the bot.
- **Roll back previous release** switches code and Python dependencies back to
  the preceding release, then starts it. Current environment variables and shared
  data are kept. Database migrations and external changes cannot be rolled back.
- **Open project in terminal / Copy project path** helps inspect deployed files.
- **Remove bot** stops/disables its service and archives the whole project on the
  VPS by default. Permanent deletion requires the explicit checkbox.

A running process does not prove Telegram connectivity. Use your bot's startup
logs and test it in Telegram. Long polling needs no incoming port. Webhook bots
need their own reachable HTTPS endpoint and server configuration; Zeravi does not
provision domains, certificates, proxies, or Telegram webhooks. Avoid starting
multiple polling processes with the same token.

## Persistent data and release layout

All bots belong to the connected SSH user:

```text
~/.local/share/zeravi/bots/<id>/
  manifest.json
  config.json             # private runtime settings, including environment values
  environment             # private systemd EnvironmentFile
  current -> releases/r-...
  releases/r-.../
    app/
    venv/
    release.json
  shared/
    data/
    uploads/
    storage/
~/.config/systemd/user/zeravi-bot-<id>.service
```

`data`, `uploads`, and `storage` are persistent by default. Listed top-level
paths are linked into the shared directory and survive ZIP updates. Add another
top-level name such as `bot.sqlite` if your app stores its database there.
An absent file path is linked on an update after it first exists; folders without
an extension are created automatically. `ZERAVI_DATA_DIR` points to `shared`, so
an app can also explicitly store data beneath that directory. Take backups of
shared data independently; rollback is not a backup.

Unlisted project files are replaced by ZIP updates. Removing a persistent name
from settings unlinks it in the current project but keeps the shared copy.
Releases are retained on the VPS; plan disk capacity for code and virtual
environments. Archived removals live under `bots/_archives/`; inspect the path
in deployment activity. Manage retention/backups yourself for now.

ZIP uploads are private temporary files and removed after an operation. Runtime
config and environment files use mode `0600`, hosting directories use `0700`,
and services use a private umask and `NoNewPrivileges`. Tokens are transported in
SSH stdin, not shell arguments, and are not stored in Zeravi's local database.
Known environment values (four or more characters) and credential URLs are
masked in retrieved output where possible. Avoid logging credentials: transformed
or partial values may still appear. The SSH user and root can read bot secrets.

Zeravi blocks normal disconnect/exit during a hosting operation. If the network
fails, reconnect and refresh before retrying: the server may have completed the
operation. Server-side locking prevents concurrent mutations of hosting state.

## Development checks

```sh
python3 -m unittest discover -s test -p 'test_bot_hosting.py' -v
python3 tool/verify_hosting_unit.py   # needs systemd-analyze
flutter analyze
flutter test
```

For SSH/SFTP integration, install `asyncssh` in a disposable development Python
environment, start `tool/test_ssh_server.py`, and pass its printed fixture path:

```sh
flutter test --dart-define=SSH_FIXTURE=/tmp/zeravi-ssh-.../fixture.json
flutter test tool/bot_hosting_preview_test.dart tool/workspace_preview_test.dart \
  --dart-define=SSH_FIXTURE=/tmp/zeravi-ssh-.../fixture.json
```

The fixture uses real loopback SSH/SFTP and the production hosting manager with
simulated OS commands. It never installs bot dependencies or changes real user
services. Production deployments still require validation on your target VPS.
