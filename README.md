# Zeravi

A local Flutter desktop workspace for remote Linux servers. Connect through SSH,
browse remote files, use your system file manager for transfers, open terminals,
and keep an eye on the server from one app.

**Preview · Ubuntu Linux x64 is the tested target.** Other platform folders are
Flutter scaffolding; a web build is not supported.

![Zeravi server overview](docs/images/overview.png)

*Screenshots use a disposable test server with synthetic monitoring data.*

## What is included

- Saved SSH profiles, key/password authentication and explicit host-key trust.
- **Overview:** live CPU history, RAM, swap, load, uptime and interface traffic.
- Filesystem capacity and top-process views, with refresh/pause/polling controls.
- A VPS file browser that works with Nautilus instead of duplicating local Files.
- Native incoming file/folder drops, including drops onto remote folder rows.
- Native outgoing file/folder copies using completed local export staging.
- Recursive transfers, empty folders, overwrite/merge confirmation and progress.
- Sort by name, size, modification time or type; descending order and folders first.
- Hidden-file and compact-row toggles, file properties and copy-path actions.
- Back/forward, parent, home and root navigation, plus keyboard shortcuts.
- Multiple independent SSH terminals and a UTF-8 text editor with conflict checks.
- Open remote paths in local VS Code through an existing Remote SSH alias.
- Persisted theme, browser settings, monitoring interval and terminal visibility.

## Run on Ubuntu

Tested with **Flutter 3.47.7 / Dart 3.13.5**. Install Flutter's Linux desktop
prerequisites (Clang, CMake, Ninja, pkg-config and GTK development libraries), then:

```sh
flutter doctor -v
flutter pub get
flutter run -d linux
```

Native drag-and-drop uses `super_drag_and_drop`, whose build integration uses
Rust or downloads its prebuilt native component when Rust is absent.

Choose **Add connection**, enter the server hostname/IP, port and username, and
select an existing private key or password authentication. Check the first-use
host fingerprint against your server console or administrator before trusting it.
Passwords and key passphrases are requested when connecting and are not saved.

## Daily workflow

**Overview** opens when connected. CPU percentages and network rates need two
samples. Missing server commands or restricted metrics remain unavailable; failed
refreshes leave the last successful reading visible with an error. Process CPU
is the lifetime average reported by `ps`. Polling is read-only and needs no root.

**Files** shows remote contents. Drag local files/folders from Nautilus onto the
browser or onto a remote folder row. To download, drag a remote item into Nautilus.
The native data provider downloads a complete export copy before supplying its
local file URI. Large exports take time: progress appears in Zeravi while the
file manager waits. **Export and reveal in Files** also prepares a local copy and
opens its containing folder, useful when a file manager times out during a large
drag. Sources stay intact; these operations are copies, never moves.

**Editor** opens when a regular UTF-8 text file is selected. The preview supports
one file up to 1 MiB; use **Save** or **Ctrl+S**. Existing server changes are checked
before saving. Use **+** in the terminal bar for another SSH shell. Hiding the
terminal panel preserves its shells. Right-click copies a selection or pastes.

### Shortcuts

| Shortcut | Action |
| --- | --- |
| Ctrl+S | Save the open editor file |
| Ctrl+H | Toggle hidden files |
| Ctrl+L | Focus the remote path |
| Ctrl+F | Focus the file-name filter |
| F5 | Refresh the current remote folder |
| Alt+Left / Alt+Right | Back / forward |

### Open in VS Code

Install VS Code, make its `code` command available, and install **Remote - SSH**.
Create a matching alias in your existing local `~/.ssh/config`:

```sshconfig
Host my-server
    HostName your-server.example
    User ubuntu
    IdentityFile ~/.ssh/id_ed25519
```

Set **VS Code SSH alias** to `my-server` in the connection form. Zeravi launches
the existing alias; it does not edit SSH configuration or install extensions.

![Zeravi remote file browser](docs/images/files.png)

## Build and test

```sh
flutter analyze
flutter test
flutter build linux --release
./build/linux/x64/release/bundle/zeravi
```

Keep the executable together with the bundle's `lib` and `data` folders.
For real SSH checks, install `asyncssh` in a Python virtual environment and run:

```sh
python tool/test_ssh_server.py
```

It prints a temporary JSON path. Keep that loopback-only server running, and in
another terminal use the printed path:

```sh
flutter test --concurrency=1 \
  --dart-define=SSH_FIXTURE=/printed/path/fixture.json \
  test tool/workspace_preview_test.dart
```

The fixture uses generated keys, disposable files, synthetic monitoring data and
an echo-only shell. It never executes arbitrary test input as a system command.
Stop it with Ctrl+C. Default tests skip SSH checks when no fixture is supplied.
UI previews are generated in `build/previews/`. Widget tests disable the native
drag engine; they exercise incoming drop messages and the exact outgoing export
provider. A physical Nautilus drag is a separate desktop smoke check.

## Storage and current limits

Profiles, trusted fingerprints and preferences are stored in `zeravi.sqlite` in
the platform application-support directory. Passwords, passphrases and key
contents are not persisted. Keyring integration is planned.

Exports are retained in the application's `zeravi-exports` temporary directory
for up to 24 hours; stale copies are cleaned on a later export. This gives the
system file manager time to finish copying. Failed preparations do not publish a
URI. Symbolic links/special files are skipped and POSIX permissions are not
replicated. Each copied file is staged before replacement. Folder batches are
not transactions, and completed files remain after a later failure. Replacing
existing VPS files requires POSIX rename support.

The preview supports one connected server and one plain-text editor alongside
multiple shells. Editor checks and writes are not atomic; an interrupted editor
save can leave partial content. Changed host keys require manual investigation;
there is no reset-trust button. SSH agent/ProxyJump, transfer resume/cancellation,
services/log controls, tunnels, deployment and editor tabs remain planned.

- [Expected desktop workflow and implemented checklist](docs/USER_EXPECTATIONS.md)
- [Architecture and data handling](docs/ARCHITECTURE.md)
- [Project plan](docs/PROJECT_PLAN.md)
