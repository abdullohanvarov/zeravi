# Zeravi project plan

Zeravi is a Flutter desktop workspace for remote Linux servers. The GUI runs
locally; SSH and SFTP provide the remote connection. Ubuntu is the first target.

## Milestones

1. **Connection foundation** — Material 3 desktop shell, Riverpod dependency
   management, SQLite profiles, password/key authentication, explicit host-key
   trust, connection/disconnection/error handling, dark and light themes.
2. **Daily workspace** — SFTP browsing, uploads/downloads with progress, folders
   and renaming, SSH terminal tabs, remote text editing, and local VS Code Remote
   SSH integration. Deliver a usable vertical slice before expanding features.
3. **Server operations** — CPU/RAM/disk/network dashboard, processes, systemd
   services, searchable live logs, saved commands, and SSH tunnels.
4. **Product polish** — deployment flows, persistent layout/tab restoration,
   transfer queue, split terminals, syntax highlighting, keyring
   integration, SSH config import, packaging and cross-platform validation.

## First implementation scope

- Store connection metadata and trusted host fingerprints in SQLite.
- Keep passwords/passphrases only in memory. Never copy private keys into storage.
- Ask before trusting an unknown server; reject changed host keys.
- Support one connected server at a time with multiple independent terminals.
- Browse SFTP directories, filter the current folder, make folders, rename,
  upload/download individual files and edit UTF-8 text up to 1 MiB.
- Confirm overwrites, protect unsaved editor content, and report failures visibly.
- Require an existing SSH config alias for Open in VS Code, without rewriting
  the user's SSH configuration.
- No real-VPS connections or writes are made automatically during development;
  integration checks use a disposable loopback-only server.

## Structure

- `lib/data`: connection model and SQLite repository.
- `lib/services`: SSH/SFTP lifecycle and local VS Code launch.
- `lib/ui`: connection form, workspace, editor, and terminal widgets.
- `lib/main.dart`: application theme, Riverpod bootstrap and startup errors.

## Validation

Run formatting, Flutter analysis, model/repository and UI tests, and a Linux
release build. Exercise SSH/SFTP against a disposable local server when available.
A real VPS smoke test is separate: trust a verified fingerprint, browse a folder,
open a terminal, transfer a disposable file, edit it, then disconnect/reconnect.

## Deferred details

Recursive deletion, permissions editing, reconnect automation, conflict resolution,
remote GUI applications, ProxyJump/SSH agent support, and full SSH config parsing
are not part of the first slice. File saves detect changes before writing, but
SFTP cannot guarantee an atomic compare-and-swap across all server types.

## Progress — 2 November 2026

Connection foundation and the first daily-workspace slice are implemented.
The current preview includes persisted profiles, host-key trust, password/key
login, SFTP browsing and individual transfers, folder creation and renaming,
multiple SSH terminal tabs, one plain-text editor, VS Code launch, themes,
resizable panels, and error handling.

Validation: static analysis clean; nine checks pass, including a loopback SSH/SFTP
integration test and a connected-workspace UI smoke test. The local fixture covers
both authentication methods, rejected/changed host keys, file roundtrips, edit
conflicts, shell I/O, terminal tabs and responsive layout. A Linux release bundle
is generated. Real-VPS compatibility and launching an actual VS Code Remote SSH
session remain manual checks.

Next implementation target: server dashboard and service/log views, followed by
editor tabs/syntax highlighting, safer atomic file replacement and transfer
queue/cancellation. Keyring storage and persistence of theme/layout remain open.


## Drag-and-drop transfers

Implemented a local file pane beside the VPS browser in Files & transfers mode.
Files and folders can be dragged in either direction, including onto destination
folder rows. Native incoming desktop drops upload to the displayed VPS folder.
Folder transfers include nested/empty folders and hidden files; links and special
files are skipped. Preflight checks detect type conflicts and request confirmation
before merging folders or replacing files. Files are staged before replacement,
with per-batch byte progress. Sources are retained.

Tests cover real SSH tree roundtrips, collisions, changed destinations, symlink
handling and actual UI drag gestures, native drop events and overwrite prompts.
Direct native drag-out into an external file manager remains future work.

## Native desktop and administration iteration

The embedded local file browser has been removed. Zeravi integrates with the
system file manager for incoming drops and lazy staged native exports. The app
now opens on a Linux overview with resource metrics, CPU history, filesystem
capacity and top-process information. File browsing adds persisted sort/visibility
preferences, history navigation, file details, copy paths, shortcuts and a
hideable terminal that retains live shells. See USER_EXPECTATIONS.md for scope.

The static monitoring command and model parsers are tested with synthetic Linux
data. Export tests verify complete file/folder trees before URI handoff. Actual
Nautilus drag gestures remain part of the manual desktop smoke test.

## Python bot hosting — 3 November 2026

Implemented the Bots workspace: validated ZIP deployment, isolated requirements
installation, systemd user services, runtime settings and environment variables,
start/stop/restart, resource/status polling, journal logs, persistent paths, ZIP
updates, previous-release rollback and archive-first removal. Setup checks explain
Python, user-manager and linger prerequisites. No real VPS is modified by tests.

Validation covers the remote lifecycle and failure recovery with temporary files
and simulated OS commands, real SSH/SFTP protocol integration, service-file syntax
with systemd-analyze, and connected Flutter workflow/preview checks. Production
VPS compatibility remains a separate deployment check. Future hosting work includes
release retention policies, backup automation, multiple Python versions and
webhook/proxy provisioning.
