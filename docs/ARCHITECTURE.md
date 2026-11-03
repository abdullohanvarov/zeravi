# Architecture

Zeravi's Flutter GUI runs locally. `dartssh2` connects directly to the server;
SFTP handles files and read-only SSH commands collect Linux monitoring data.
No Zeravi backend or server agent is required.

| Location | Responsibility |
| --- | --- |
| `lib/main.dart` | Riverpod bootstrap, startup errors, persisted theme |
| `lib/data/app_store.dart` | SQLite profiles, trusted host keys and preferences |
| `lib/data/file_view.dart` | File filtering, sort order and browsing preferences |
| `lib/services/remote_session.dart` | SSH/SFTP lifecycle, editor operations |
| `lib/services/vscode_launcher.dart` | Managed SSH metadata and local VS Code launch |
| `lib/services/file_transfer.dart` | Recursive preflight, collision checks and staged copies |
| `lib/services/export_cache.dart` | Completed local copies for native file-manager exports |
| `lib/services/server_monitor.dart` | Bounded Linux probes, snapshot parsing, deltas and polling |
| `lib/data/bot_project.dart` | ZIP metadata validation and hosting models |
| `lib/services/bot_hosting.dart` | SSH hosting protocol, SFTP ZIP upload and operation state |
| `assets/hosting/manager.py` | Transient remote release builder and managed user-service operations |
| `lib/ui/bot_hosting_panel.dart` | Deployment, runtime settings, readiness, bot cards and logs |
| `lib/ui/workspace.dart` | Navigation, file browser, editor, shortcuts and user prompts |
| `lib/ui/server_dashboard.dart` | Resource cards, history, filesystem and process tables |
| `lib/ui/transfer_widgets.dart` | Lazy native file-URI drag provider |
| `lib/ui/ssh_terminal.dart` | Independent SSH channels and terminal lifecycle |

## Monitoring

A static read-only command reads Linux `/proc` files, `uname`, `df` and `ps`.
User-provided strings are never interpolated into that command. CPU usage is the
difference of successive CPU counters; guest counters are excluded to avoid
counting guest work twice. Memory usage is total minus available. Network rates
use counter deltas for the default interface when available, with an interface
name displayed. Counter resets produce an unavailable rate, not a negative rate.

Only one probe runs at a time. Commands are bounded by a timeout and collected
output is capped. Monitoring stops on disconnect/disposal, can be paused, and
retains the last successful snapshot if a later probe fails. Process command
names are shown without full argument strings. Polling does not require sudo.

## Native file-manager transfers

`desktop_drop` receives incoming OS file paths. The browser identifies the folder
under the drop pointer or uses the current directory. Uploads use the same
preflight and staged transfer engine as menu-based uploads.

`super_drag_and_drop` supplies an outgoing lazy `fileUri`. The provider downloads
the selected remote file/tree to a private temporary directory, then resolves to
a local URI only after successful completion. Requests within one drag share one
preparation future. Only copy operations are offered. Export copies survive drag
completion so Nautilus can finish reading; stale copies are cleaned after 24h on
a subsequent export. Failed preparation cleans its staging directory.

Tests cover the export boundary and incoming platform messages; native desktop
handshakes require a physical desktop smoke check.

## Persistence and identity

SQLite holds connection metadata, key-file references, trusted fingerprints and
preferences. A settings table is added without changing existing profile data.
Passwords/passphrases and private-key contents are not stored. Unknown hosts
require explicit trust, changed keys are rejected, and the system's known-hosts file is not rewritten. VS Code receives separate
arguments and an encoded URI. An explicit user-provided SSH alias is preserved.
When the alias is blank, the launcher writes metadata-only managed Host entries
and a backed-up Include in the local SSH config so VS Code can reuse the saved
connection. Existing config symlinks and manual Host entries are preserved.


## Workspace layout

The terminal dock stays at the right side of the workspace and keeps its SSH
channels alive while hidden or maximized. Splitters resize connections, the editor
explorer, and the terminal; preferences clamp persisted widths for smaller windows.
Grid and list entries share the same context-menu and native drag implementations.
Opening a folder terminal sends a safely shell-quoted `cd` command to a fresh
interactive SSH shell; no remote file name is interpreted as shell syntax.

## Bot hosting

The app sends a static Python helper over an SSH execution channel. Request JSON
arrives on stdin; tokens and project settings are not interpolated into shell
commands. Responses are newline-delimited JSON progress/result/error events.
Uploads use exclusive private SFTP files and are independently validated remotely.
The helper uses argv arrays for pip/systemd/journal commands, a server-side mutation
lock, private metadata and environment files, and immutable release directories.

A release is created at its final path before building the virtual environment,
so environment scripts retain valid absolute paths. Dependencies install before
stopping an existing bot. Activation switches a relative current symlink and
updates the user service; startup-command failures restore the previous release
and settings when possible. Runtime crashes are reported through service state
and journal logs. Shared data is retained independently of release selection.

The helper is transient; the bot itself continues as a systemd user service.
Normal app exit/disconnect is blocked during a hosting operation. Connection loss
can leave the operation completed or in progress remotely; reconnect and refresh
before retrying. See BOT_HOSTING.md for readiness, storage and security limits.
