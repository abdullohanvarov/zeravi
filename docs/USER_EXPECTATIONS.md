# Zeravi desktop administration checklist

## This iteration

- [x] Use the system file manager instead of an embedded local file browser.
- [x] Drag local files/folders from Nautilus into the VPS browser to upload.
- [x] Drag remote files/folders to Nautilus using a completed local export copy.
- [x] Show preparation/progress and retain originals during copies.
- [x] Show live CPU use, RAM/swap, load, uptime, root-disk capacity and network rates.
- [x] Provide filesystem capacity and process-resource views without root access.
- [x] Handle unavailable commands/metrics visibly rather than inventing values.
- [x] Pause monitoring, refresh manually, and choose the polling interval.
- [x] Sort files by name, size, modification time or type; reverse the order.
- [x] Toggle hidden files, folders first, compact rows and the terminal panel.
- [x] Persist browsing preferences and theme locally.
- [x] Navigate back/forward, up, home and root; refresh or focus the path with shortcuts.
- [x] Show file size, modification time and permissions; copy full paths and inspect details.
- [x] Keep existing overwrite checks, host trust, editor conflict checks and SSH terminals.

## Later

General service administration, SSH tunnels, other deployment types, multi-selection, transfer
resume/cancellation, richer permission editing, and syntax highlighting remain
separate roadmap items. Native dragging is a copy operation, never a remote move.


## Layout and editor integration additions

- [x] Open in VS Code from saved SSH details without a mandatory manual alias.
- [x] Show useful setup errors instead of raw state exceptions.
- [x] Switch between saved grid and list views with identical file actions.
- [x] Right-click folders to open a focused terminal tab in that exact folder.
- [x] Dock terminals on the right and preserve them when hidden/maximized.
- [x] Resize connections, the editor explorer and terminal with saved widths.
- [x] Collapse connections into an icon rail.
- [x] Reset layout, double-click splitters to reset, and label tabs by folder.

## Python Telegram bot hosting

- [x] Inspect a ZIP and select its requirements folder and Python entry point.
- [x] Upload through SFTP and build a separate Python environment on the VPS.
- [x] Show deployment progress and dependency installation output.
- [x] Start, stop, restart and inspect managed user-service status and resources.
- [x] View/search/copy recent logs with automatic refresh.
- [x] Edit private environment variables, boot startup and restart policy.
- [x] Preserve configured data paths across ZIP updates.
- [x] Keep the old process running while new dependencies install.
- [x] Roll back code/dependencies and archive projects on removal by default.
- [x] Check VPS readiness and provide one-time setup guidance.

See [BOT_HOSTING.md](BOT_HOSTING.md) for prerequisites and current limits.
