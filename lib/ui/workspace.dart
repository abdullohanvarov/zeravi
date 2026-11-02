import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:dartssh2/dartssh2.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../data/app_store.dart';
import '../data/connection.dart';
import '../services/remote_session.dart';
import '../services/vscode_launcher.dart';
import 'resize_handle.dart';
import '../services/file_transfer.dart';
import '../data/file_view.dart';
import '../services/server_monitor.dart';
import '../services/export_cache.dart';
import 'server_dashboard.dart';
import 'transfer_widgets.dart';
import 'connection_dialog.dart';
import 'ssh_terminal.dart';

class Workspace extends StatefulWidget {
  const Workspace({
    super.key,
    required this.store,
    required this.onToggleTheme,
    this.nativeDragEnabled = true,
  });
  final bool nativeDragEnabled;
  final AppStore store;
  final VoidCallback onToggleTheme;
  @override
  State<Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<Workspace> {
  late List<ServerConnection> connections = widget.store.connections();
  RemoteSession? session;
  ServerConnection? connecting;
  final pathController = TextEditingController();
  final filterController = TextEditingController();
  final editorController = TextEditingController();
  String path = '';
  String filter = '';
  String? selectedPath;
  bool selectedDirectory = false;
  List<SftpName> entries = [];
  String? fileError;
  String? editorPath;
  String originalText = '';
  bool dirty = false;
  bool loading = false;
  bool working = false;
  String? transferLabel;
  double? transferProgress;
  int listingGeneration = 0;
  late final AppLifecycleListener lifecycle;
  int nextTerminal = 1;
  final terminalIds = <int>[];
  final terminalDirectories = <int, String>{};
  int activeTerminal = 0;
  late final viewSettings = FileViewSettings.load(widget.store);
  ServerMonitor? monitor;
  final exports = ExportCache();
  String workspaceView = 'overview';
  final pathFocus = FocusNode();
  final filterFocus = FocusNode();
  final history = <String>[];
  int historyIndex = -1;
  String? homePath;
  final folderDropKeys = <String, GlobalKey>{};
  String? nativeDropPath;
  bool nativeHover = false;

  @override
  void initState() {
    super.initState();
    lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        if (working) {
          message(
            'Wait for the current file operation to finish before closing.',
          );
          return AppExitResponse.cancel;
        }
        return await discardChanges()
            ? AppExitResponse.exit
            : AppExitResponse.cancel;
      },
    );
    editorController.addListener(() {
      final changed = editorController.text != originalText;
      if (changed != dirty && mounted) setState(() => dirty = changed);
    });
  }

  @override
  void dispose() {
    lifecycle.dispose();
    monitor?.dispose();
    session?.close();
    pathFocus.dispose();
    filterFocus.dispose();
    pathController.dispose();
    filterController.dispose();
    editorController.dispose();
    super.dispose();
  }

  void message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text), showCloseIcon: true));
  }

  Future<bool> confirm(
    String title,
    String body, {
    String action = 'Continue',
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: SizedBox(width: 420, child: Text(body)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  Future<bool> discardChanges() async =>
      !dirty ||
      await confirm(
        'Discard unsaved changes?',
        'Your changes to ${p.posix.basename(editorPath ?? '')} have not been saved.',
        action: 'Discard changes',
      );

  Future<void> editConnection([ServerConnection? connection]) async {
    final result = await showDialog<ServerConnection>(
      context: context,
      builder: (_) => ConnectionDialog(connection: connection),
    );
    if (result == null || !mounted) return;
    try {
      widget.store.save(result);
      setState(() => connections = widget.store.connections());
    } catch (error) {
      message('Could not save connection: $error');
    }
  }

  Future<void> deleteConnection(ServerConnection connection) async {
    if (!await confirm(
      'Remove ${connection.name}?',
      'This removes the saved profile from Zeravi. Your server and SSH key file are unaffected.',
      action: 'Remove',
    )) {
      return;
    }
    try {
      widget.store.delete(connection.id);
      if (mounted) setState(() => connections = widget.store.connections());
    } catch (error) {
      message('Could not remove connection: $error');
    }
  }

  Future<void> connect(ServerConnection connection) async {
    if (connecting != null || working || !await discardChanges() || !mounted) {
      return;
    }
    final secret = await requestSecret(context, connection);
    if (secret == null || !mounted) return;
    final previous = session;
    setState(() {
      session = null;
      connecting = connection;
      terminalIds.clear();
      terminalDirectories.clear();
      entries = [];
      editorPath = null;
      originalText = '';
      editorController.clear();
      path = '';
      pathController.clear();
      fileError = null;
      listingGeneration++;
    });
    monitor?.dispose();
    monitor = null;
    history.clear();
    historyIndex = -1;
    homePath = null;
    previous?.close();
    try {
      final remote = await RemoteSession.connect(
        connection,
        widget.store,
        secret,
        (type, fingerprint) async {
          if (!mounted) return false;
          return await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Trust this server?'),
                  content: SizedBox(
                    width: 480,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'First connection to ${connection.host}:${connection.port}.',
                        ),
                        const SizedBox(height: 16),
                        Text(type),
                        const SizedBox(height: 8),
                        SelectableText(
                          fingerprint,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'Compare this fingerprint with the server administrator or your server console before trusting it.',
                        ),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Trust and connect'),
                    ),
                  ],
                ),
              ) ??
              false;
        },
      );
      if (!mounted) {
        remote.close();
        return;
      }
      setState(() {
        session = remote;
        workspaceView = 'overview';
        connecting = null;
        addTerminal();
      });
      monitor = ServerMonitor(remote.client, seconds: viewSettings.pollSeconds);
      remote.client.done.then(
        (_) => connectionLost(remote),
        onError: (Object error) => connectionLost(remote, error),
      );
      await loadDirectory('.');
    } catch (error) {
      if (mounted) {
        setState(() => connecting = null);
        message('Connection failed: $error');
      }
    }
  }

  void connectionLost(RemoteSession remote, [Object? error]) {
    if (!mounted || session != remote) return;
    monitor?.dispose();
    monitor = null;
    setState(() {
      session = null;
      terminalIds.clear();
      terminalDirectories.clear();
      entries.clear();
      loading = false;
      listingGeneration++;
    });
    message(
      'Connection closed${error == null ? '' : ': $error'}. Unsaved editor content is still available to copy.',
    );
  }

  Future<void> disconnect() async {
    if (working || !await discardChanges() || !mounted) return;
    final remote = session;
    monitor?.dispose();
    monitor = null;
    setState(() {
      session = null;
      terminalIds.clear();
      terminalDirectories.clear();
      entries.clear();
      path = '';
      pathController.clear();
      editorPath = null;
      originalText = '';
      editorController.clear();
      loading = false;
      listingGeneration++;
    });
    remote?.close();
  }

  Future<void> loadDirectory(String target, {bool addHistory = true}) async {
    final remote = session;
    if (remote == null) return;
    final generation = ++listingGeneration;
    setState(() {
      loading = true;
      fileError = null;
    });
    try {
      final resolved = await remote.sftp.absolute(target);
      final result = await remote.list(resolved);
      if (!mounted || generation != listingGeneration || remote != session) {
        return;
      }
      setState(() {
        homePath ??= resolved;
        if (addHistory &&
            (historyIndex < 0 || history[historyIndex] != resolved)) {
          if (historyIndex < history.length - 1) {
            history.removeRange(historyIndex + 1, history.length);
          }
          history.add(resolved);
          historyIndex = history.length - 1;
        }
        folderDropKeys.clear();
        path = resolved;
        pathController.text = resolved;
        entries = result;
        selectedPath = null;
        loading = false;
      });
    } catch (error) {
      if (mounted && generation == listingGeneration) {
        setState(() {
          fileError = '$error';
          loading = false;
          pathController.text = path;
        });
      }
    }
  }

  Future<void> perform(Future<void> Function() action) async {
    if (working) return;
    setState(() => working = true);
    try {
      await action();
    } catch (error) {
      message('$error');
    } finally {
      if (mounted) {
        setState(() {
          working = false;
          transferLabel = null;
          transferProgress = null;
        });
      }
    }
  }

  Future<void> openEntry(SftpName entry) async {
    final fullPath = p.posix.join(path, entry.filename);
    if (entry.attr.isDirectory) {
      await loadDirectory(fullPath);
      return;
    }
    if (working || !await discardChanges() || !mounted) return;
    final remote = session;
    if (remote == null) return;
    await perform(() async {
      // Follow symbolic links only when opening them, preserving the shown path.
      final attrs = await remote.sftp.stat(fullPath);
      if (attrs.isDirectory) {
        await loadDirectory(fullPath);
        return;
      }
      final text = await remote.readText(fullPath);
      if (!mounted || session != remote) return;
      setState(() {
        workspaceView = 'editor';
        editorPath = fullPath;
        originalText = text;
        editorController.text = text;
        dirty = false;
      });
    });
  }

  Future<void> saveEditor() async {
    final remote = session;
    final target = editorPath;
    if (remote == null || target == null || !dirty || working) return;
    final contents = editorController.text;
    await perform(() async {
      await remote.saveText(target, originalText, contents);
      if (!mounted) return;
      setState(() {
        originalText = contents;
        dirty = editorController.text != contents;
      });
      message('Saved ${p.posix.basename(target)}');
      await loadDirectory(path);
    });
  }

  Future<String?> askName(String title, {String initial = ''}) async {
    final controller = TextEditingController(text: initial);
    final form = GlobalKey<FormState>();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Form(
          key: form,
          child: TextFormField(
            controller: controller,
            autofocus: true,
            validator: validateFileName,
            decoration: const InputDecoration(labelText: 'Name'),
            onFieldSubmitted: (_) {
              if (form.currentState!.validate()) {
                Navigator.pop(context, controller.text);
              }
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) {
                Navigator.pop(context, controller.text);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.dispose();
    return result;
  }

  Future<void> createFolder() async {
    final remote = session;
    final directory = path;
    if (remote == null || directory.isEmpty || working) return;
    final name = await askName('New folder');
    if (name == null || !mounted || remote != session) return;
    await perform(() async {
      await remote.sftp.mkdir(p.posix.join(directory, name));
      await loadDirectory(directory);
    });
  }

  Future<void> renameEntry(SftpName entry) async {
    final remote = session;
    final directory = path;
    if (remote == null || working) return;
    final source = p.posix.join(directory, entry.filename);
    if (editorPath == source || (editorPath?.startsWith('$source/') ?? false)) {
      message('Close the open editor before renaming this file or folder.');
      return;
    }
    final name = await askName(
      'Rename ${entry.filename}',
      initial: entry.filename,
    );
    if (name == null ||
        name == entry.filename ||
        !mounted ||
        remote != session) {
      return;
    }
    await perform(() async {
      final existing = await remote.list(directory);
      if (existing.any((e) => e.filename == name)) {
        throw StateError('That name already exists.');
      }
      await remote.sftp.rename(source, p.posix.join(directory, name));
      await loadDirectory(directory);
    });
  }

  void progress(String label, int total, int bytes) {
    if (mounted) {
      setState(() {
        transferLabel = label;
        transferProgress = total > 0 ? (bytes / total).clamp(0, 1) : null;
      });
    }
  }

  Future<void> transferFiles(
    TransferDirection direction,
    List<String> sources,
    String destination,
  ) async {
    final remote = session;
    if (remote == null || working || destination.isEmpty || sources.isEmpty) {
      return;
    }
    await perform(() async {
      setState(() {
        transferLabel = 'Preparing transfer…';
        nativeHover = false;
      });
      final transfer = FileTransfer(remote);
      final plan = await transfer.prepare(direction, sources, destination);
      if (!mounted || session != remote) return;
      if (plan.items.isEmpty) {
        message(
          'No transferable files. Symbolic links and special files are skipped.',
        );
        return;
      }
      if (direction == TransferDirection.upload &&
          dirty &&
          plan.items.any((item) => item.destination == editorPath)) {
        message('Save or close your unsaved editor file before replacing it.');
        return;
      }
      final collision = plan.overwrites > 0 || plan.merges > 0;
      if (collision &&
          !await confirm(
            'Files already exist',
            '${plan.overwrites} file(s) will be replaced and ${plan.merges} folder(s) merged in $destination. Other destination files will stay in place.',
            action: 'Merge and replace',
          )) {
        return;
      }
      if (!mounted || session != remote) return;
      await transfer.execute(
        plan,
        overwriteApproved: collision,
        onProgress: (name, completed, total) => progress(
          '${direction == TransferDirection.upload ? 'Uploading' : 'Downloading'} ${p.posix.basename(name)}',
          total,
          completed,
        ),
      );
      if (!mounted || session != remote) return;
      await loadDirectory(path);
      if (direction == TransferDirection.upload &&
          editorPath != null &&
          !dirty &&
          plan.items.any(
            (item) => !item.directory && item.destination == editorPath,
          )) {
        final text = await remote.readText(editorPath!);
        if (mounted) {
          setState(() {
            originalText = text;
            editorController.text = text;
          });
        }
      }
      message(
        'Copied ${plan.files} file(s) and ${plan.folders} folder(s)${plan.skipped > 0 ? '; skipped ${plan.skipped} symbolic link(s) or special file(s)' : ''}.',
      );
    });
  }

  Future<void> upload() async {
    final remote = session;
    final directory = path;
    if (remote == null || directory.isEmpty || working) return;
    final files = await openFiles();
    if (!mounted || remote != session) return;
    await transferFiles(
      TransferDirection.upload,
      files.map((file) => file.path).toList(),
      directory,
    );
  }

  Future<void> uploadFolder() async {
    final remote = session;
    final directory = path;
    if (remote == null || directory.isEmpty || working) return;
    final source = await getDirectoryPath(confirmButtonText: 'Upload folder');
    if (source != null && mounted && remote == session) {
      await transferFiles(TransferDirection.upload, [source], directory);
    }
  }

  Future<void> download(SftpName entry) async {
    final remote = session;
    final source = p.posix.join(path, entry.filename);
    if (remote == null || working) return;
    final destination = await getDirectoryPath(
      confirmButtonText: 'Download here',
    );
    if (destination != null && mounted && remote == session) {
      await transferFiles(TransferDirection.download, [source], destination);
    }
  }

  Future<void> vscode(String target, bool directory) async {
    final remote = session;
    if (remote == null) return;
    await perform(
      () => openConnectionInVSCode(
        remote.connection,
        target,
        directory: directory,
      ),
    );
  }

  void addTerminal({String? directory}) {
    final id = nextTerminal++;
    terminalIds.add(id);
    if (directory != null && directory.isNotEmpty) {
      terminalDirectories[id] = directory;
    }
    activeTerminal = terminalIds.length - 1;
  }

  void openFolderTerminal(String directory) {
    if (session == null) return;
    changeViewSettings(() {
      viewSettings.showTerminal = true;
      addTerminal(directory: directory.isEmpty ? null : directory);
    });
  }

  void closeTerminal(int index) {
    final id = terminalIds[index];
    final currentId = terminalIds.isEmpty ? null : terminalIds[activeTerminal];
    terminalIds.removeAt(index);
    terminalDirectories.remove(id);
    activeTerminal = currentId != id
        ? terminalIds.indexOf(currentId!)
        : index.clamp(0, terminalIds.isEmpty ? 0 : terminalIds.length - 1);
    if (activeTerminal < 0) activeTerminal = 0;
  }

  void resetLayout() => changeViewSettings(() {
    viewSettings.connectionsCollapsed = false;
    viewSettings.connectionsWidth = 224;
    viewSettings.explorerWidth = 300;
    viewSettings.terminalWidth = 420;
    viewSettings.terminalMaximized = false;
    viewSettings.showTerminal = true;
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyB, control: true): () =>
            changeViewSettings(
              () => viewSettings.connectionsCollapsed =
                  !viewSettings.connectionsCollapsed,
            ),
        const SingleActivator(
          LogicalKeyboardKey.keyT,
          control: true,
          alt: true,
        ): () =>
            openFolderTerminal(path),
        const SingleActivator(LogicalKeyboardKey.keyH, control: true): () =>
            changeViewSettings(
              () => viewSettings.showHidden = !viewSettings.showHidden,
            ),
        const SingleActivator(LogicalKeyboardKey.keyL, control: true): () {
          setState(() {
            workspaceView = 'files';
            viewSettings.terminalMaximized = false;
          });
          pathFocus.requestFocus();
        },
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () {
          setState(() {
            workspaceView = 'files';
            viewSettings.terminalMaximized = false;
          });
          filterFocus.requestFocus();
        },
        const SingleActivator(LogicalKeyboardKey.f5): () {
          if (session != null) loadDirectory(path);
        },
        const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): () =>
            navigateHistory(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true): () =>
            navigateHistory(1),
        const SingleActivator(LogicalKeyboardKey.keyS, control: true):
            saveEditor,
      },
      child: Scaffold(
        body: Column(
          children: [
            Container(
              height: 68,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: Theme.of(context).dividerColor),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: colors.primary,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.bolt_rounded, color: colors.onPrimary),
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    'zeravi',
                    style: TextStyle(
                      fontSize: 23,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -1,
                    ),
                  ),
                  const SizedBox(width: 22),
                  if (MediaQuery.sizeOf(context).width > 760)
                    Text(
                      'YOUR REMOTE WORKSPACE',
                      style: TextStyle(
                        fontSize: 10,
                        letterSpacing: 2,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  const Spacer(),
                  if (session != null) ...[
                    Icon(Icons.circle, color: colors.primary, size: 7),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        session!.connection.name,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 12),
                    TextButton.icon(
                      onPressed: working ? null : disconnect,
                      icon: const Icon(Icons.power_settings_new, size: 16),
                      label: const Text('Disconnect'),
                    ),
                  ],
                  IconButton(
                    onPressed: widget.onToggleTheme,
                    icon: const Icon(Icons.contrast_rounded),
                    tooltip: 'Toggle light / dark theme',
                  ),
                ],
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final sidebarWidth = viewSettings.connectionsCollapsed
                      ? 60.0
                      : viewSettings.connectionsWidth.clamp(
                          190.0,
                          (constraints.maxWidth * .3).clamp(190.0, 350.0),
                        );
                  return Row(
                    children: [
                      SizedBox(
                        width: sidebarWidth,
                        child: viewSettings.connectionsCollapsed
                            ? connectionsRail()
                            : sidebar(),
                      ),
                      if (viewSettings.connectionsCollapsed)
                        const VerticalDivider(width: 1)
                      else
                        HorizontalResizeHandle(
                          key: const ValueKey('connections-resize-handle'),
                          label: 'Resize connections',
                          onDelta: (delta) => setState(
                            () => viewSettings.connectionsWidth =
                                (sidebarWidth + delta).clamp(190, 350),
                          ),
                          onEnd: () => changeViewSettings(() {}),
                          onReset: () => changeViewSettings(
                            () => viewSettings.connectionsWidth = 224,
                          ),
                        ),
                      Expanded(
                        child: session == null && editorPath == null
                            ? welcome()
                            : remoteWorkspace(),
                      ),
                    ],
                  );
                },
              ),
            ),
            Container(
              height: 30,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: colors.surfaceContainerLow,
                border: Border(
                  top: BorderSide(color: Theme.of(context).dividerColor),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    session != null
                        ? Icons.lock_outline
                        : Icons.circle_outlined,
                    size: 12,
                    color: colors.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      transferLabel ??
                          (connecting != null
                              ? 'Connecting to ${connecting!.name}…'
                              : session != null
                              ? 'SSH / SFTP  •  ${session!.connection.address}'
                              : 'Local workspace  •  No server connected'),
                      style: const TextStyle(fontSize: 11),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (transferLabel != null)
                    SizedBox(
                      width: 120,
                      child: LinearProgressIndicator(value: transferProgress),
                    ),
                  const SizedBox(width: 16),
                  const Text(
                    'ZERAVI  /  PREVIEW',
                    style: TextStyle(fontSize: 9, letterSpacing: 1.5),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget connectionsRail() => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    child: Column(
      children: [
        const SizedBox(height: 12),
        IconButton(
          tooltip: 'Expand connections (Ctrl+B)',
          onPressed: () => changeViewSettings(
            () => viewSettings.connectionsCollapsed = false,
          ),
          icon: const Icon(Icons.chevron_right),
        ),
        IconButton(
          tooltip: 'Add server',
          onPressed: () => editConnection(),
          icon: const Icon(Icons.add),
        ),
        const Divider(),
        Expanded(
          child: ListView(
            children: [
              for (final connection in connections)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: IconButton(
                    tooltip: '${connection.name}\n${connection.host}',
                    isSelected: session?.connection.id == connection.id,
                    onPressed:
                        connecting != null ||
                            working ||
                            session?.connection.id == connection.id
                        ? null
                        : () => connect(connection),
                    icon: const Icon(Icons.dns_outlined),
                    selectedIcon: Icon(
                      Icons.dns,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget sidebar() {
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: colors.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'CONNECTIONS',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 1.8,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Collapse connections (Ctrl+B)',
                  constraints: const BoxConstraints.tightFor(
                    width: 28,
                    height: 32,
                  ),
                  padding: EdgeInsets.zero,
                  onPressed: () => changeViewSettings(
                    () => viewSettings.connectionsCollapsed = true,
                  ),
                  icon: const Icon(Icons.chevron_left, size: 20),
                ),
                IconButton(
                  tooltip: 'Add server',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => editConnection(),
                  icon: const Icon(Icons.add, size: 19),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: connections.isEmpty
                  ? Text(
                      'Your servers will appear here.',
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                        height: 1.6,
                      ),
                    )
                  : ListView.separated(
                      itemCount: connections.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 6),
                      itemBuilder: (context, index) {
                        final connection = connections[index];
                        final active = session?.connection.id == connection.id;
                        return Material(
                          color: active
                              ? colors.primaryContainer.withValues(alpha: .4)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: active || connecting != null || working
                                ? null
                                : () => connect(connection),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(10, 12, 0, 12),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.dns_outlined,
                                    size: 19,
                                    color: active
                                        ? colors.primary
                                        : colors.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          connection.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(height: 3),
                                        Text(
                                          connection.host,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 10,
                                            color: colors.onSurfaceVariant,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  PopupMenuButton<String>(
                                    tooltip: 'Connection actions',
                                    enabled: !active && connecting == null,
                                    iconSize: 17,
                                    padding: EdgeInsets.zero,
                                    onSelected: (value) => value == 'edit'
                                        ? editConnection(connection)
                                        : deleteConnection(connection),
                                    itemBuilder: (_) => const [
                                      PopupMenuItem(
                                        value: 'edit',
                                        child: Text('Edit connection'),
                                      ),
                                      PopupMenuItem(
                                        value: 'remove',
                                        child: Text('Remove connection'),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            OutlinedButton.icon(
              onPressed: () => editConnection(),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add connection'),
            ),
            const SizedBox(height: 20),
            Divider(color: Theme.of(context).dividerColor),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(
                  Icons.desktop_windows_outlined,
                  size: 16,
                  color: colors.primary,
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Runs on your device',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'One place for your remote work.',
              style: TextStyle(fontSize: 10, color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget welcome() {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(36),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 660),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: colors.primary.withValues(alpha: .1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  'LOCAL COMFORT. REMOTE POWER.',
                  style: TextStyle(
                    color: colors.primary,
                    fontSize: 10,
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Your servers.\nA familiar workspace.',
                style: TextStyle(
                  fontSize: 38,
                  height: 1.15,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -1.5,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Browse files, open a shell, and edit your projects.\nEverything together, connected securely over SSH.',
                style: TextStyle(
                  fontSize: 14,
                  height: 1.8,
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 28),
              if (connecting != null)
                Row(
                  children: [
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 12),
                    Text('Connecting to ${connecting!.name}…'),
                  ],
                )
              else
                FilledButton.icon(
                  onPressed: connections.isEmpty
                      ? () => editConnection()
                      : () => connect(connections.first),
                  icon: const Icon(Icons.add_link_rounded, size: 18),
                  label: Text(
                    connections.isEmpty
                        ? 'Connect your first server'
                        : 'Connect to ${connections.first.name}',
                  ),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 20,
                    ),
                  ),
                ),
              const SizedBox(height: 48),
              Wrap(
                spacing: 14,
                runSpacing: 14,
                children: [
                  featureCard(
                    Icons.folder_open_rounded,
                    'Files, within reach',
                    'Browse and transfer over SFTP.',
                  ),
                  featureCard(
                    Icons.terminal_rounded,
                    'Room to work',
                    'Independent SSH terminal tabs.',
                  ),
                  featureCard(
                    Icons.code_rounded,
                    'Your editor, connected',
                    'Edit here or open in VS Code.',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget featureCard(IconData icon, String title, String description) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: 202,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: colors.primary, size: 22),
          const SizedBox(height: 20),
          Text(
            title,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            description,
            style: TextStyle(
              fontSize: 11,
              height: 1.6,
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Future<Uri> exportForFileManager(String source) async {
    final remote = session;
    if (remote == null || working) {
      throw StateError('Wait for the active transfer to finish.');
    }
    setState(() {
      working = true;
      transferLabel = 'Preparing export for Files…';
    });
    try {
      final uri = await exports.prepare(
        remote,
        source,
        (name, bytes, total) => progress(
          'Preparing ${p.posix.basename(name)} for Files',
          total,
          bytes,
        ),
      );
      message('Export ready for your file manager.');
      return uri;
    } catch (error) {
      message('Export failed: $error');
      rethrow;
    } finally {
      if (mounted) {
        setState(() {
          working = false;
          transferLabel = null;
          transferProgress = null;
        });
      }
    }
  }

  void changeViewSettings(void Function() change) {
    setState(change);
    try {
      viewSettings.save(widget.store);
    } catch (e) {
      message('Could not save preferences: $e');
    }
  }

  Future<void> navigateHistory(int offset) async {
    final next = historyIndex + offset;
    if (next < 0 || next >= history.length || loading) return;
    final target = history[next];
    await loadDirectory(target, addHistory: false);
    if (mounted && path == target) setState(() => historyIndex = next);
  }

  Future<void> fileProperties(SftpName entry) async {
    final date = entry.attr.modifyTime == null
        ? 'Unknown'
        : DateTime.fromMillisecondsSinceEpoch(entry.attr.modifyTime! * 1000)
              .toLocal()
              .toString();
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(entry.filename),
        content: SizedBox(
          width: 480,
          child: SelectableText(
            'Path: ${p.posix.join(path, entry.filename)}\nType: ${entry.attr.isDirectory
                ? 'Folder'
                : entry.attr.isSymbolicLink
                ? 'Symbolic link'
                : 'File'}\nSize: ${humanBytes(entry.attr.size)}\nModified: $date\nPermissions: ${permissionsText(entry)}\nOwner UID: ${entry.attr.userID ?? 'Unknown'} · GID: ${entry.attr.groupID ?? 'Unknown'}',
            style: const TextStyle(fontSize: 13, height: 1.8),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  String? folderAt(Offset global) {
    for (final entry in folderDropKeys.entries) {
      final box = entry.value.currentContext?.findRenderObject();
      if (box is RenderBox &&
          box.attached &&
          box.size.contains(box.globalToLocal(global))) {
        return entry.key;
      }
    }
    return null;
  }

  Widget remoteWorkspace() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'overview',
                      icon: Icon(Icons.monitor_heart_outlined, size: 17),
                      label: Text('Overview'),
                    ),
                    ButtonSegment(
                      value: 'files',
                      icon: Icon(Icons.folder_open, size: 17),
                      label: Text('Files'),
                    ),
                    ButtonSegment(
                      value: 'editor',
                      icon: Icon(Icons.edit_outlined, size: 17),
                      label: Text('Editor'),
                    ),
                  ],
                  selected: {workspaceView},
                  onSelectionChanged: (value) => setState(() {
                    workspaceView = value.first;
                    viewSettings.terminalMaximized = false;
                  }),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Reset layout',
              onPressed: resetLayout,
              icon: const Icon(Icons.reset_tv, size: 20),
            ),
            IconButton(
              tooltip: viewSettings.showTerminal
                  ? 'Hide terminal panel'
                  : 'Show terminal panel',
              icon: const Icon(Icons.terminal),
              onPressed: () => changeViewSettings(() {
                viewSettings.showTerminal = !viewSettings.showTerminal;
                viewSettings.terminalMaximized = false;
              }),
            ),
          ],
        ),
      ),
      if (working) const LinearProgressIndicator(minHeight: 2),
      Expanded(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final minimum = (width * .4).clamp(0.0, 240.0);
            final minimumPrimary = (width * .5).clamp(0.0, 300.0);
            final maximum = (width - minimumPrimary - 8).clamp(minimum, width);
            final terminalWidth = viewSettings.terminalWidth.clamp(
              minimum,
              maximum,
            );
            final show = session != null && viewSettings.showTerminal;
            return Row(
              children: [
                SizedBox(
                  width: show && viewSettings.terminalMaximized
                      ? 0
                      : show
                      ? width - terminalWidth - 8
                      : width,
                  child: Offstage(
                    offstage: show && viewSettings.terminalMaximized,
                    child: OverflowBox(
                      alignment: Alignment.topLeft,
                      minWidth: show
                          ? (width - terminalWidth - 8).clamp(0.0, width)
                          : width,
                      maxWidth: show
                          ? (width - terminalWidth - 8).clamp(0.0, width)
                          : width,
                      minHeight: constraints.maxHeight,
                      maxHeight: constraints.maxHeight,
                      child: primaryWorkspace(),
                    ),
                  ),
                ),
                if (show && !viewSettings.terminalMaximized)
                  HorizontalResizeHandle(
                    key: const ValueKey('terminal-resize-handle'),
                    label: 'Resize terminal',
                    onDelta: (delta) => setState(
                      () => viewSettings.terminalWidth = (terminalWidth - delta)
                          .clamp(minimum, maximum),
                    ),
                    onEnd: () => changeViewSettings(() {}),
                    onReset: () => changeViewSettings(
                      () => viewSettings.terminalWidth = 420,
                    ),
                  ),
                if (session != null)
                  Offstage(
                    offstage: !show,
                    child: SizedBox(
                      key: const ValueKey('right-terminal-pane'),
                      width: viewSettings.terminalMaximized && show
                          ? width
                          : terminalWidth,
                      height: constraints.maxHeight,
                      child: terminals(),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    ],
  );

  Widget primaryWorkspace() => LayoutBuilder(
    builder: (context, constraints) {
      if (workspaceView == 'overview' && monitor != null) {
        return ServerDashboard(
          monitor: monitor!,
          onInterval: (seconds) {
            changeViewSettings(() => viewSettings.pollSeconds = seconds);
            monitor!.configure(interval: seconds);
          },
        );
      }
      if (workspaceView == 'files') return files();
      if (constraints.maxWidth < 660) return editor();
      final maximum = (constraints.maxWidth - 300).clamp(220.0, 700.0);
      final explorerWidth = viewSettings.explorerWidth.clamp(220.0, maximum);
      return Row(
        children: [
          SizedBox(width: explorerWidth, child: files()),
          HorizontalResizeHandle(
            key: const ValueKey('explorer-resize-handle'),
            label: 'Resize file explorer',
            onDelta: (delta) => setState(
              () => viewSettings.explorerWidth = (explorerWidth + delta).clamp(
                220,
                maximum,
              ),
            ),
            onEnd: () => changeViewSettings(() {}),
            onReset: () =>
                changeViewSettings(() => viewSettings.explorerWidth = 300),
          ),
          Expanded(child: editor()),
        ],
      );
    },
  );

  Widget files() {
    final enabled =
        session != null &&
        !viewSettings.terminalMaximized &&
        !working &&
        !loading &&
        path.isNotEmpty &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    return DropTarget(
      key: const ValueKey('remote-drop-zone'),
      enable: enabled,
      onDragEntered: (details) => setState(() {
        nativeHover = true;
        nativeDropPath = folderAt(details.globalPosition);
      }),
      onDragUpdated: (details) =>
          setState(() => nativeDropPath = folderAt(details.globalPosition)),
      onDragExited: (_) => setState(() {
        nativeHover = false;
        nativeDropPath = null;
      }),
      onDragDone: (details) {
        setState(() => nativeHover = false);
        transferFiles(
          TransferDirection.upload,
          details.files.map((file) => file.path).toList(),
          folderAt(details.globalPosition) ?? path,
        );
      },
      child: Stack(
        children: [
          _remoteFilesContent(),
          if (nativeHover && enabled)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary
                        .withValues(alpha: .14),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.primary,
                      width: 2,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'Release to upload into ${nativeDropPath == null ? 'this folder' : p.posix.basename(nativeDropPath!)}',
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _remoteFilesContent() {
    final visible = viewSettings.visible(entries, filter);
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: (constraints.maxHeight * .65).clamp(0.0, 360.0),
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'VPS FILES',
                            style: TextStyle(
                              fontSize: 10,
                              letterSpacing: 1.8,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'New folder',
                          onPressed: session == null || working
                              ? null
                              : createFolder,
                          icon: const Icon(
                            Icons.create_new_folder_outlined,
                            size: 18,
                          ),
                        ),
                        PopupMenuButton<String>(
                          tooltip: 'Upload files or folder',
                          enabled: session != null && !working,
                          icon: const Icon(Icons.upload_file_rounded, size: 18),
                          onSelected: (value) =>
                              value == 'folder' ? uploadFolder() : upload(),
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                              value: 'files',
                              child: Text('Upload files'),
                            ),
                            PopupMenuItem(
                              value: 'folder',
                              child: Text('Upload folder'),
                            ),
                          ],
                        ),
                        IconButton(
                          tooltip: 'Refresh folder',
                          onPressed: session == null
                              ? null
                              : () => loadDirectory(path),
                          icon: const Icon(Icons.refresh_rounded, size: 18),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          IconButton(
                            tooltip: 'Back (Alt+Left)',
                            onPressed: historyIndex > 0 && !loading
                                ? () => navigateHistory(-1)
                                : null,
                            icon: const Icon(Icons.arrow_back, size: 18),
                          ),
                          IconButton(
                            tooltip: 'Forward (Alt+Right)',
                            onPressed:
                                historyIndex < history.length - 1 && !loading
                                ? () => navigateHistory(1)
                                : null,
                            icon: const Icon(Icons.arrow_forward, size: 18),
                          ),
                          IconButton(
                            tooltip: 'Home folder',
                            onPressed: homePath == null
                                ? null
                                : () => loadDirectory(homePath!),
                            icon: const Icon(Icons.home_outlined, size: 18),
                          ),
                          IconButton(
                            tooltip: 'Filesystem root',
                            onPressed: session == null
                                ? null
                                : () => loadDirectory('/'),
                            icon: const Icon(
                              Icons.account_tree_outlined,
                              size: 18,
                            ),
                          ),
                          IconButton(
                            tooltip: viewSettings.showHidden
                                ? 'Hide dot files (Ctrl+H)'
                                : 'Show dot files (Ctrl+H)',
                            isSelected: viewSettings.showHidden,
                            onPressed: () => changeViewSettings(
                              () => viewSettings.showHidden =
                                  !viewSettings.showHidden,
                            ),
                            icon: const Icon(
                              Icons.visibility_outlined,
                              size: 18,
                            ),
                          ),
                          IconButton(
                            tooltip:
                                'Open current folder in terminal (Ctrl+Alt+T)',
                            onPressed: session == null
                                ? null
                                : () => openFolderTerminal(path),
                            icon: const Icon(Icons.terminal, size: 18),
                          ),
                          IconButton(
                            key: const ValueKey('grid-view-toggle'),
                            tooltip: viewSettings.gridView
                                ? 'Switch to list view'
                                : 'Switch to grid view',
                            isSelected: viewSettings.gridView,
                            onPressed: () => changeViewSettings(
                              () => viewSettings.gridView =
                                  !viewSettings.gridView,
                            ),
                            icon: Icon(
                              viewSettings.gridView
                                  ? Icons.view_list
                                  : Icons.grid_view,
                              size: 20,
                            ),
                          ),
                          PopupMenuButton<String>(
                            tooltip: 'Sort and view options',
                            icon: const Icon(Icons.sort, size: 20),
                            onSelected: (value) => changeViewSettings(() {
                              if (value.startsWith('sort-')) {
                                viewSettings.sort = FileSort.values.byName(
                                  value.substring(5),
                                );
                              }
                              if (value == 'descending') {
                                viewSettings.descending =
                                    !viewSettings.descending;
                              }
                              if (value == 'folders') {
                                viewSettings.foldersFirst =
                                    !viewSettings.foldersFirst;
                              }
                              if (value == 'compact') {
                                viewSettings.compact = !viewSettings.compact;
                              }
                            }),
                            itemBuilder: (_) => [
                              for (final sort in FileSort.values)
                                CheckedPopupMenuItem(
                                  value: 'sort-${sort.name}',
                                  checked: viewSettings.sort == sort,
                                  child: Text('Sort by ${sort.name}'),
                                ),
                              const PopupMenuDivider(),
                              CheckedPopupMenuItem(
                                value: 'descending',
                                checked: viewSettings.descending,
                                child: const Text('Descending order'),
                              ),
                              CheckedPopupMenuItem(
                                value: 'folders',
                                checked: viewSettings.foldersFirst,
                                child: const Text('Folders first'),
                              ),
                              CheckedPopupMenuItem(
                                value: 'compact',
                                checked: viewSettings.compact,
                                child: const Text('Compact rows'),
                              ),
                            ],
                          ),
                          IconButton(
                            tooltip: 'Copy current path',
                            onPressed: path.isEmpty
                                ? null
                                : () {
                                    Clipboard.setData(
                                      ClipboardData(text: path),
                                    );
                                    message('Path copied.');
                                  },
                            icon: const Icon(Icons.copy, size: 17),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: 'Parent folder',
                          onPressed: session == null || path == '/'
                              ? null
                              : () => loadDirectory(p.posix.dirname(path)),
                          icon: const Icon(Icons.arrow_upward, size: 17),
                        ),
                        Expanded(
                          child: TextField(
                            key: const ValueKey('remote-path'),
                            focusNode: pathFocus,
                            controller: pathController,
                            enabled: session != null,
                            style: const TextStyle(fontSize: 12),
                            decoration: const InputDecoration(
                              hintText: 'Remote path',
                              contentPadding: EdgeInsets.all(10),
                            ),
                            onSubmitted: (value) => loadDirectory(value),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: TextField(
                      controller: filterController,
                      focusNode: filterFocus,
                      style: const TextStyle(fontSize: 12),
                      decoration: const InputDecoration(
                        hintText: 'Filter this folder (Ctrl+F)',
                        prefixIcon: Icon(Icons.search, size: 17),
                        contentPadding: EdgeInsets.all(10),
                      ),
                      onChanged: (value) => setState(() => filter = value),
                    ),
                  ),
                  if (fileError != null)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        fileError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  if (loading) const LinearProgressIndicator(minHeight: 2),
                ],
              ),
            ),
          ),
          Expanded(
            child: visible.isEmpty
                ? Center(
                    child: Text(
                      loading
                          ? 'Loading files…'
                          : entries.isEmpty
                          ? 'This folder is empty'
                          : filter.isNotEmpty
                          ? 'No matching files'
                          : 'No visible files — try showing dot files',
                      style: const TextStyle(fontSize: 12),
                    ),
                  )
                : viewSettings.gridView
                ? GridView.builder(
                    key: const ValueKey('remote-grid'),
                    padding: const EdgeInsets.all(12),
                    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: viewSettings.compact ? 140 : 180,
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      mainAxisExtent: viewSettings.compact ? 118 : 148,
                    ),
                    itemCount: visible.length,
                    itemBuilder: (_, index) =>
                        remoteEntry(visible[index], grid: true),
                  )
                : ListView.builder(
                    key: const ValueKey('remote-list'),
                    itemCount: visible.length,
                    itemBuilder: (_, index) =>
                        remoteEntry(visible[index], grid: false),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Text(
                  '${visible.length} of ${entries.length} items',
                  style: const TextStyle(fontSize: 10),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: session == null || path.isEmpty || working
                      ? null
                      : () => vscode(
                          selectedPath ?? path,
                          selectedPath == null || selectedDirectory,
                        ),
                  icon: const Icon(Icons.open_in_new, size: 13),
                  label: const Text('VS Code', style: TextStyle(fontSize: 11)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<PopupMenuEntry<String>> entryMenu(SftpName entry) => [
    PopupMenuItem(
      value: 'terminal',
      child: Text(
        entry.attr.isDirectory ? 'Open in terminal' : 'Open parent in terminal',
      ),
    ),
    PopupMenuItem(
      value: 'code',
      enabled: !working,
      child: const Text('Open in VS Code'),
    ),
    const PopupMenuDivider(),
    PopupMenuItem(
      value: 'rename',
      enabled: !working,
      child: const Text('Rename'),
    ),
    PopupMenuItem(
      value: 'download',
      enabled: !working,
      child: const Text('Download to…'),
    ),
    PopupMenuItem(
      value: 'export',
      enabled: !working,
      child: const Text('Export and reveal in Files'),
    ),
    const PopupMenuItem(value: 'copy', child: Text('Copy full path')),
    const PopupMenuItem(value: 'properties', child: Text('Properties')),
  ];

  void entryAction(String action, SftpName entry, String fullPath) {
    if (action == 'terminal') {
      openFolderTerminal(
        entry.attr.isDirectory ? fullPath : p.posix.dirname(fullPath),
      );
      return;
    }
    if (action == 'code') vscode(fullPath, entry.attr.isDirectory);
    if (action == 'copy') {
      Clipboard.setData(ClipboardData(text: fullPath));
      message('Path copied.');
    }
    if (action == 'properties') fileProperties(entry);
    if (action == 'rename') renameEntry(entry);
    if (action == 'download') download(entry);
    if (action == 'export') {
      exportForFileManager(fullPath).then((uri) async {
        try {
          await Process.run('xdg-open', [File.fromUri(uri).parent.path]);
        } catch (e) {
          message('Could not open Files: $e');
        }
      }, onError: (Object _) {});
    }
  }

  Future<void> entryContextMenu(
    SftpName entry,
    String fullPath,
    Offset position,
  ) async {
    setState(() {
      selectedPath = fullPath;
      selectedDirectory = entry.attr.isDirectory;
    });
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final point = overlay.globalToLocal(position);
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(point.dx, point.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: entryMenu(entry),
    );
    if (action != null && mounted) entryAction(action, entry, fullPath);
  }

  Widget remoteEntry(SftpName entry, {required bool grid}) {
    final fullPath = p.posix.join(path, entry.filename);
    final colors = Theme.of(context).colorScheme;
    final icon = entry.attr.isDirectory
        ? Icons.folder_rounded
        : entry.attr.isSymbolicLink
        ? Icons.link
        : Icons.insert_drive_file_outlined;
    void open() {
      setState(() {
        selectedPath = fullPath;
        selectedDirectory = entry.attr.isDirectory;
      });
      openEntry(entry);
    }

    final menu = PopupMenuButton<String>(
      tooltip: 'File actions',
      iconSize: 16,
      onSelected: (value) => entryAction(value, entry, fullPath),
      itemBuilder: (_) => entryMenu(entry),
    );
    Widget tile = grid
        ? Material(
            color: selectedPath == fullPath
                ? colors.primaryContainer.withValues(alpha: .35)
                : colors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: open,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 18, 12, 10),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            icon,
                            size: viewSettings.compact ? 32 : 42,
                            color: entry.attr.isDirectory
                                ? colors.primary
                                : colors.onSurfaceVariant,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            entry.filename,
                            maxLines: 2,
                            textAlign: TextAlign.center,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                          if (!viewSettings.compact) ...[
                            const SizedBox(height: 4),
                            Text(
                              entry.attr.isDirectory
                                  ? 'Folder'
                                  : humanBytes(entry.attr.size),
                              style: TextStyle(
                                fontSize: 10,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  Positioned(top: 0, right: 0, child: menu),
                ],
              ),
            ),
          )
        : ListTile(
            dense: true,
            visualDensity: viewSettings.compact
                ? const VisualDensity(vertical: -4)
                : VisualDensity.standard,
            selected: selectedPath == fullPath,
            selectedTileColor: colors.primary.withValues(alpha: .08),
            contentPadding: const EdgeInsets.only(left: 18, right: 4),
            leading: Icon(
              icon,
              size: 20,
              color: entry.attr.isDirectory
                  ? colors.primary
                  : colors.onSurfaceVariant,
            ),
            title: Text(
              entry.filename,
              style: const TextStyle(fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: viewSettings.compact
                ? null
                : Text(
                    '${entry.attr.isDirectory ? 'Folder' : humanBytes(entry.attr.size)} · ${modifiedText(entry)} · ${permissionsText(entry)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10),
                  ),
            onTap: open,
            trailing: menu,
          );
    tile = GestureDetector(
      key: ValueKey('remote-entry-$fullPath'),
      behavior: HitTestBehavior.opaque,
      onSecondaryTapUp: (details) =>
          entryContextMenu(entry, fullPath, details.globalPosition),
      child: Tooltip(
        message:
            '$fullPath\n${modifiedText(entry)} · ${permissionsText(entry)}',
        child: tile,
      ),
    );
    tile = NativeExportDrag(
      enabled: widget.nativeDragEnabled && !entry.attr.isSymbolicLink,
      canStart: () => session != null && !working,
      name: entry.filename,
      prepare: () => exportForFileManager(fullPath),
      child: tile,
    );
    if (entry.attr.isDirectory) {
      tile = KeyedSubtree(
        key: folderDropKeys.putIfAbsent(fullPath, () => GlobalKey()),
        child: tile,
      );
    }
    return tile;
  }

  Widget editor() {
    if (editorPath == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.data_object_rounded,
                size: 44,
                color: Theme.of(context).colorScheme.onSurfaceVariant
                    .withValues(alpha: .4),
              ),
              const SizedBox(height: 20),
              const Text(
                'Make yourself at home',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 10),
              Text(
                'Open a file from the explorer to start editing.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'CTRL + S   Save file',
                style: TextStyle(fontSize: 10, fontFamily: 'monospace'),
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      children: [
        Container(
          height: 48,
          padding: const EdgeInsets.only(left: 16, right: 8),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.description_outlined, size: 16),
              const SizedBox(width: 10),
              Expanded(
                child: Tooltip(
                  message: editorPath!,
                  child: Text(
                    '${p.posix.basename(editorPath!)}${dirty ? ' •' : ''}',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
              TextButton(
                onPressed: !dirty || working || session == null
                    ? null
                    : saveEditor,
                child: const Text('Save'),
              ),
              IconButton(
                tooltip: 'Close file',
                icon: const Icon(Icons.close, size: 17),
                onPressed: working
                    ? null
                    : () async {
                        if (!await discardChanges() || !mounted) return;
                        setState(() {
                          editorPath = null;
                          originalText = '';
                          editorController.clear();
                        });
                      },
              ),
            ],
          ),
        ),
        Expanded(
          child: TextField(
            controller: editorController,
            expands: true,
            maxLines: null,
            minLines: null,
            readOnly: working || session == null,
            keyboardType: TextInputType.multiline,
            autocorrect: false,
            enableSuggestions: false,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              height: 1.65,
            ),
            decoration: const InputDecoration(
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: EdgeInsets.all(20),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
          child: Row(
            children: [
              Text(
                session == null
                    ? 'Disconnected • Copy unsaved text before reconnecting'
                    : 'UTF-8  •  Plain text',
                style: const TextStyle(fontSize: 10),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget terminals() => Column(
    children: [
      Container(
        height: 42,
        padding: const EdgeInsets.only(left: 12, right: 4),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          border: Border(
            bottom: BorderSide(color: Theme.of(context).dividerColor),
          ),
        ),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                'TERMINAL',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10, letterSpacing: 1.5),
              ),
            ),
            IconButton(
              tooltip: 'New terminal',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.add, size: 18),
              onPressed: () => openFolderTerminal(path),
            ),
            IconButton(
              tooltip: viewSettings.terminalMaximized
                  ? 'Restore terminal size'
                  : 'Maximize terminal',
              visualDensity: VisualDensity.compact,
              icon: Icon(
                viewSettings.terminalMaximized
                    ? Icons.fullscreen_exit
                    : Icons.fullscreen,
                size: 18,
              ),
              onPressed: () => setState(
                () => viewSettings.terminalMaximized =
                    !viewSettings.terminalMaximized,
              ),
            ),
            IconButton(
              tooltip: 'Hide terminal',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, size: 17),
              onPressed: () => changeViewSettings(() {
                viewSettings.showTerminal = false;
                viewSettings.terminalMaximized = false;
              }),
            ),
          ],
        ),
      ),
      SizedBox(
        height: 38,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          itemCount: terminalIds.length,
          itemBuilder: (context, index) {
            final id = terminalIds[index],
                directory = terminalDirectories[terminalIds[index]];
            return Container(
              key: ValueKey('terminal-tab-$id'),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    width: 2,
                    color: activeTerminal == index
                        ? Theme.of(context).colorScheme.primary
                        : Colors.transparent,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Tooltip(
                    message: directory ?? 'SSH login directory',
                    child: TextButton(
                      onPressed: () => setState(() => activeTerminal = index),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 150),
                        child: Text(
                          directory == null
                              ? 'Shell $id'
                              : '${p.posix.basename(directory)} · $id',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close shell $id',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 13),
                    onPressed: () => setState(() => closeTerminal(index)),
                  ),
                ],
              ),
            );
          },
        ),
      ),
      Expanded(
        child: terminalIds.isEmpty
            ? Center(
                child: TextButton.icon(
                  onPressed: () => openFolderTerminal(path),
                  icon: const Icon(Icons.add),
                  label: const Text('Open a terminal'),
                ),
              )
            : IndexedStack(
                index: activeTerminal,
                children: [
                  for (var index = 0; index < terminalIds.length; index++)
                    SshTerminal(
                      key: ValueKey(
                        '${session.hashCode}-${terminalIds[index]}',
                      ),
                      session: session!,
                      initialDirectory: terminalDirectories[terminalIds[index]],
                      active:
                          viewSettings.showTerminal && activeTerminal == index,
                    ),
                ],
              ),
      ),
    ],
  );
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String permissionsText(SftpName entry) => entry.attr.mode == null
    ? 'Unknown permissions'
    : (entry.attr.mode!.value & 0x1ff).toRadixString(8).padLeft(3, '0');
String modifiedText(SftpName entry) {
  final seconds = entry.attr.modifyTime;
  if (seconds == null) return 'Unknown date';
  final time = DateTime.fromMillisecondsSinceEpoch(seconds * 1000).toLocal();
  return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
}
