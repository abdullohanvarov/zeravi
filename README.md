# Zeravi

A local desktop workspace for remote Linux servers, built with Flutter.
The interface runs on your computer; SSH and SFTP connect it to your server.

## Run on Ubuntu

```sh
flutter pub get
flutter run -d linux
```

The first launch opens an empty workspace. Choose **Add connection**, enter a
hostname/IP and username, and select an SSH private key or password authentication.
Verify the server fingerprint when connecting for the first time.

Build a standalone desktop bundle:

```sh
flutter build linux --release
./build/linux/x64/release/bundle/zeravi
```

Keep the executable together with the bundle's `lib` and `data` directories.
Flutter's Linux development prerequisites include Clang, CMake, Ninja, pkg-config,
and GTK development libraries. The tested target is Ubuntu Linux x64.

## Available in this preview

- Material 3 dark/light workspace with resizable file and terminal panels.
- SQLite saved connection profiles; edit and remove profiles while disconnected.
- Password and private-key authentication, including a key passphrase prompt.
- Explicit first-use host fingerprint trust; changed host keys are rejected.
- Side-by-side local and VPS file browsers with drag-and-drop copies in both
  directions, including nested and empty folders.
- Drop files/folders from Ubuntu Files onto the VPS pane to upload. Drop onto
  folder rows inside Zeravi to choose a destination folder.
- SFTP path navigation, filtering, folder creation, renaming, multi-file uploads
  and recursive downloads, with progress and overwrite/merge confirmation.
- Multiple interactive SSH terminal tabs. Right-click copies the selection or
  pastes clipboard text when there is no selection.
- One UTF-8 text editor (up to 1 MiB), Ctrl+S, unsaved-change prompts, and a
  remote-content check before saving. Binary files are rejected.
- Open remote files/folders in local VS Code through an existing SSH host alias.
- Visible errors and connection state. Disconnecting unexpectedly keeps the
  editor's unsaved content available to copy.

## Open in VS Code

Install VS Code, make its `code` command available, and install **Remote - SSH**.
Create a host alias in your local `~/.ssh/config`, for example:

```sshconfig
Host my-server
    HostName your-server.example
    User ubuntu
    Port 22
    IdentityFile ~/.ssh/id_ed25519
```

Set **VS Code SSH alias** to `my-server` in Zeravi's connection form. That alias
must point to the same server as the saved profile. Zeravi checks the extension
and launches `code` with separate arguments and an encoded remote URI. It does
not edit SSH configuration or install extensions automatically.

## Storage and current limits

Profiles and trusted host fingerprints are stored in `zeravi.sqlite` in the
platform application-support directory. Passwords and key passphrases are held
only in memory. Private keys are read from the selected file and never copied
into the database. System-keyring credential saving is planned.

This first version supports one connected server at a time and one open text
file, alongside multiple shells. The editor is plain text; syntax highlighting
and editor tabs are planned. Monitoring, services, logs, tunnels, deployment,
recursive deletion, transfer queues and workspace restore are also planned. No remote desktop/display server is needed for the implemented features.

Transfers copy items and keep the source. Symbolic links and special files are
skipped to avoid following loops or copying outside the selected tree. Each file
is staged beside its destination before replacement; folder transfers complete
one file at a time. Replacing existing VPS files requires the server to support
POSIX rename; otherwise the transfer fails while preserving the existing file.
Failed transfers can leave completed files in a partially copied folder. Transfer
retry/resume is future work. Dragging VPS files directly into an external file
manager is not implemented; use the Local files pane for downloads.

Editor saves check for remote changes before writing, but that check and the write
are not atomic. Interrupted editor saves can leave partial remote content.
Changed host keys currently require manual investigation; there is
no in-app reset-trust action yet. SSH agent, ProxyJump and SSH config import are
not implemented. Theme/layout settings are not yet persisted.

## Checks

```sh
flutter analyze
flutter test
```

The default suite covers profile storage, host-trust isolation, input validation,
VS Code URI construction, and connection-form/window-layout behavior.
The real SSH integration test is skipped unless a fixture is supplied.

To test locally without touching a real server, install `asyncssh` in a Python
virtual environment and run:

```sh
python tool/test_ssh_server.py
```

This prints a temporary JSON fixture path. With that server running, use:

```sh
flutter test --dart-define=SSH_FIXTURE=/printed/path/fixture.json
flutter test tool/workspace_preview_test.dart --dart-define=SSH_FIXTURE=/printed/path/fixture.json
```

The fixture binds only to loopback, uses temporary test keys and files, and runs
an echo-only test shell. Stop it with Ctrl+C. The UI smoke test exercises drag-and-drop in both directions, folder targets,
native drop events, and overwrite confirmation. It writes screenshots
to `build/previews/` and optionally loads Ubuntu's Liberation fonts for previews.
It does not create real saved profiles or connect to your VPS.

See [the project plan](docs/PROJECT_PLAN.md) for milestones and architecture.
