import 'dart:async';
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
import '../services/file_transfer.dart';
import 'local_files.dart';
import 'transfer_widgets.dart';
import 'connection_dialog.dart';
import 'ssh_terminal.dart';

class Workspace extends StatefulWidget {
  const Workspace({
    super.key,
    required this.store,
    required this.onToggleTheme,
  });
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
  int activeTerminal = 0;
  final localFilesKey = GlobalKey<LocalFilesPaneState>();
  String? localDirectory;
  bool transferView = true;
  bool nativeHover = false;
  double fileWidth = 330;
  double terminalHeight = 240;

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
    session?.close();
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
      entries = [];
      editorPath = null;
      originalText = '';
      editorController.clear();
      path = '';
      pathController.clear();
      fileError = null;
      listingGeneration++;
    });
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
        transferView = true;
        connecting = null;
        addTerminal();
      });
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
    setState(() {
      session = null;
      terminalIds.clear();
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
    setState(() {
      session = null;
      terminalIds.clear();
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

  Future<void> loadDirectory(String target) async {
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
        transferView = false;
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
      await localFilesKey.currentState?.refresh();
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
      () => openInVSCode(
        remote.connection.vscodeAlias,
        target,
        directory: directory,
      ),
    );
  }

  void addTerminal() {
    terminalIds.add(nextTerminal++);
    activeTerminal = terminalIds.length - 1;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return CallbackShortcuts(
      bindings: {
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
                  final sidebarWidth = constraints.maxWidth < 850
                      ? 190.0
                      : 240.0;
                  return Row(
                    children: [
                      SizedBox(width: sidebarWidth, child: sidebar()),
                      VerticalDivider(
                        width: 1,
                        thickness: 1,
                        color: Theme.of(context).dividerColor,
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
                    style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 1.8,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
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

  Widget remoteWorkspace() => LayoutBuilder(
    builder: (context, constraints) {
      final stacked = constraints.maxWidth < 650;
      final browserWidth = fileWidth.clamp(
        220.0,
        (constraints.maxWidth * .55).clamp(220.0, 500.0),
      );
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(
                      value: true,
                      icon: Icon(Icons.swap_horiz, size: 16),
                      label: Text('Files & transfers'),
                    ),
                    ButtonSegment(
                      value: false,
                      icon: Icon(Icons.edit_outlined, size: 16),
                      label: Text('Editor'),
                    ),
                  ],
                  selected: {transferView},
                  onSelectionChanged: (value) =>
                      setState(() => transferView = value.first),
                ),
                if (constraints.maxWidth > 900) ...[
                  const SizedBox(width: 20),
                  const Text(
                    'Drag files or folders between panes to copy',
                    style: TextStyle(fontSize: 11),
                  ),
                ],
              ],
            ),
          ),
          if (working) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: transferView && session != null
                ? Row(
                    children: [
                      Expanded(
                        child: LocalFilesPane(
                          key: localFilesKey,
                          initialDirectory: localDirectory,
                          onDirectoryChanged: (value) => localDirectory = value,
                          session: session,
                          enabled: !working,
                          onDownload: (data, directory) => transferFiles(
                            TransferDirection.download,
                            data.paths,
                            directory,
                          ),
                        ),
                      ),
                      VerticalDivider(
                        width: 1,
                        color: Theme.of(context).dividerColor,
                      ),
                      Expanded(child: files()),
                    ],
                  )
                : stacked
                ? files()
                : Row(
                    children: [
                      SizedBox(width: browserWidth, child: files()),
                      MouseRegion(
                        cursor: SystemMouseCursors.resizeColumn,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onHorizontalDragUpdate: (details) => setState(
                            () => fileWidth = (fileWidth + details.delta.dx)
                                .clamp(220, 500),
                          ),
                          child: SizedBox(
                            width: 6,
                            child: VerticalDivider(
                              width: 6,
                              thickness: 1,
                              color: Theme.of(context).dividerColor,
                            ),
                          ),
                        ),
                      ),
                      Expanded(child: editor()),
                    ],
                  ),
          ),
          if (!transferView && stacked && editorPath != null)
            SizedBox(height: constraints.maxHeight * .35, child: editor()),
          if (session != null) ...[
            MouseRegion(
              cursor: SystemMouseCursors.resizeRow,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragUpdate: (details) => setState(
                  () => terminalHeight = (terminalHeight - details.delta.dy)
                      .clamp(100, constraints.maxHeight * .6),
                ),
                child: SizedBox(
                  height: 6,
                  child: Divider(
                    height: 6,
                    color: Theme.of(context).dividerColor,
                  ),
                ),
              ),
            ),
            SizedBox(
              height: terminalHeight.clamp(
                100.0,
                constraints.maxHeight * (stacked ? .3 : .55),
              ),
              child: terminals(),
            ),
          ],
        ],
      );
    },
  );

  Widget files() {
    final enabled =
        session != null &&
        !working &&
        !loading &&
        path.isNotEmpty &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    return DropTarget(
      enable: enabled,
      onDragEntered: (_) => setState(() => nativeHover = true),
      onDragExited: (_) => setState(() => nativeHover = false),
      onDragDone: (details) {
        setState(() => nativeHover = false);
        transferFiles(
          TransferDirection.upload,
          details.files.map((file) => file.path).toList(),
          path,
        );
      },
      child: TransferTarget(
        key: const ValueKey('remote-drop-zone'),
        accepts: (data) => enabled && data.local,
        onDrop: (data) =>
            transferFiles(TransferDirection.upload, data.paths, path),
        label: 'Release to upload here',
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
                    child: const Card(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('Release to upload files and folders'),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _remoteFilesContent() {
    final visible = entries
        .where((e) => e.filename.toLowerCase().contains(filter.toLowerCase()))
        .toList();
    return Column(
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
                onPressed: session == null || working ? null : createFolder,
                icon: const Icon(Icons.create_new_folder_outlined, size: 18),
              ),
              PopupMenuButton<String>(
                tooltip: 'Upload files or folder',
                enabled: session != null && !working,
                icon: const Icon(Icons.upload_file_rounded, size: 18),
                onSelected: (value) =>
                    value == 'folder' ? uploadFolder() : upload(),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'files', child: Text('Upload files')),
                  PopupMenuItem(value: 'folder', child: Text('Upload folder')),
                ],
              ),
              IconButton(
                tooltip: 'Refresh folder',
                onPressed: session == null ? null : () => loadDirectory(path),
                icon: const Icon(Icons.refresh_rounded, size: 18),
              ),
            ],
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
            style: const TextStyle(fontSize: 12),
            decoration: const InputDecoration(
              hintText: 'Filter this folder',
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
        Expanded(
          child: visible.isEmpty
              ? Center(
                  child: Text(
                    loading
                        ? 'Loading files…'
                        : filter.isEmpty
                        ? 'This folder is empty'
                        : 'No matching files',
                    style: const TextStyle(fontSize: 12),
                  ),
                )
              : ListView.builder(
                  itemCount: visible.length,
                  itemBuilder: (context, index) {
                    final entry = visible[index];
                    final fullPath = p.posix.join(path, entry.filename);
                    Widget tile = ListTile(
                      key: ValueKey('remote-entry-$fullPath'),
                      dense: true,
                      selected: selectedPath == fullPath,
                      selectedTileColor: Theme.of(context).colorScheme.primary
                          .withValues(alpha: .08),
                      contentPadding: const EdgeInsets.only(left: 18, right: 4),
                      leading: Icon(
                        entry.attr.isDirectory
                            ? Icons.folder_rounded
                            : entry.attr.isSymbolicLink
                            ? Icons.link
                            : Icons.insert_drive_file_outlined,
                        size: 20,
                        color: entry.attr.isDirectory
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      title: Text(
                        entry.filename,
                        style: const TextStyle(fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: entry.attr.isDirectory
                          ? null
                          : Text(
                              formatBytes(entry.attr.size ?? 0),
                              style: const TextStyle(fontSize: 10),
                            ),
                      onTap: () {
                        setState(() {
                          selectedPath = fullPath;
                          selectedDirectory = entry.attr.isDirectory;
                        });
                        openEntry(entry);
                      },
                      trailing: PopupMenuButton<String>(
                        tooltip: 'File actions',
                        iconSize: 16,
                        enabled: !working,
                        onSelected: (value) {
                          if (value == 'code') {
                            vscode(fullPath, entry.attr.isDirectory);
                          }
                          if (value == 'rename') renameEntry(entry);
                          if (value == 'download') download(entry);
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: 'code',
                            child: Text('Open in VS Code'),
                          ),
                          const PopupMenuItem(
                            value: 'rename',
                            child: Text('Rename'),
                          ),
                          const PopupMenuItem(
                            value: 'download',
                            child: Text('Download'),
                          ),
                        ],
                      ),
                    );
                    tile = TransferDrag(
                      data: FileDrag(
                        paths: [fullPath],
                        local: false,
                        session: session,
                      ),
                      name: entry.filename,
                      directory: entry.attr.isDirectory,
                      enabled:
                          session != null &&
                          !working &&
                          !entry.attr.isSymbolicLink,
                      child: tile,
                    );
                    if (entry.attr.isDirectory) {
                      tile = TransferTarget(
                        accepts: (data) => !working && data.local,
                        onDrop: (data) => transferFiles(
                          TransferDirection.upload,
                          data.paths,
                          fullPath,
                        ),
                        label: 'Upload into ${entry.filename}',
                        child: tile,
                      );
                    }
                    return tile;
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Text(
                '${visible.length} items',
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
    );
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
      SizedBox(
        height: 40,
        child: Row(
          children: [
            const SizedBox(width: 16),
            const Text(
              'TERMINAL',
              style: TextStyle(fontSize: 10, letterSpacing: 1.5),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: terminalIds.length,
                itemBuilder: (context, index) => Container(
                  margin: const EdgeInsets.only(right: 4),
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
                      TextButton(
                        onPressed: () => setState(() => activeTerminal = index),
                        child: Text(
                          'Shell ${terminalIds[index]}',
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close shell ${terminalIds[index]}',
                        icon: const Icon(Icons.close, size: 13),
                        onPressed: () => setState(() {
                          terminalIds.removeAt(index);
                          activeTerminal = activeTerminal.clamp(
                            0,
                            terminalIds.isEmpty ? 0 : terminalIds.length - 1,
                          );
                        }),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: 'New terminal',
              icon: const Icon(Icons.add, size: 18),
              onPressed: () => setState(addTerminal),
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
      Expanded(
        child: terminalIds.isEmpty
            ? Center(
                child: TextButton.icon(
                  onPressed: () => setState(addTerminal),
                  icon: const Icon(Icons.add),
                  label: const Text('Open a terminal'),
                ),
              )
            : IndexedStack(
                index: activeTerminal,
                children: [
                  for (final id in terminalIds)
                    SshTerminal(
                      key: ValueKey('${session.hashCode}-$id'),
                      session: session!,
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
