import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'transfer_widgets.dart';

class LocalFilesPane extends StatefulWidget {
  const LocalFilesPane({
    super.key,
    required this.session,
    required this.enabled,
    required this.onDownload,
    this.initialDirectory,
    this.onDirectoryChanged,
  });
  final String? initialDirectory;
  final ValueChanged<String>? onDirectoryChanged;
  final Object? session;
  final bool enabled;
  final Future<void> Function(FileDrag data, String directory) onDownload;
  @override
  State<LocalFilesPane> createState() => LocalFilesPaneState();
}

class LocalFilesPaneState extends State<LocalFilesPane> {
  final pathController = TextEditingController();
  String directory = '';
  String filter = '';
  String? error;
  bool loading = false;
  int generation = 0;
  List<FileSystemEntity> entries = [];

  @override
  void initState() {
    super.initState();
    load(
      widget.initialDirectory ??
          Platform.environment['HOME'] ??
          Directory.current.path,
    );
  }

  @override
  void dispose() {
    pathController.dispose();
    super.dispose();
  }

  Future<void> refresh() => load(directory);

  Future<void> load(String path) async {
    final current = ++generation;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final resolved = await Directory(path).resolveSymbolicLinks();
      final children = await Directory(resolved)
          .list(followLinks: false)
          .toList();
      children.sort((a, b) {
        if ((a is Directory) != (b is Directory)) {
          return a is Directory ? -1 : 1;
        }
        return p
            .basename(a.path)
            .toLowerCase()
            .compareTo(p.basename(b.path).toLowerCase());
      });
      if (!mounted || current != generation) return;
      setState(() {
        directory = resolved;
        pathController.text = resolved;
        entries = children;
        loading = false;
      });
      widget.onDirectoryChanged?.call(resolved);
    } catch (e) {
      if (mounted && current == generation) {
        setState(() {
          error = '$e';
          loading = false;
        });
      }
    }
  }

  bool accepts(FileDrag data) =>
      widget.enabled &&
      !loading &&
      !data.local &&
      data.session == widget.session &&
      directory.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final visible = entries
        .where(
          (e) =>
              p.basename(e.path).toLowerCase().contains(filter.toLowerCase()),
        )
        .toList();
    return TransferTarget(
      key: const ValueKey('local-drop-zone'),
      accepts: accepts,
      onDrop: (data) => widget.onDownload(data, directory),
      label: 'Release to download here',
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
            child: Row(
              children: [
                const Icon(Icons.computer, size: 16),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'LOCAL FILES',
                    style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 1.8,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Choose local folder',
                  icon: const Icon(Icons.folder_open, size: 18),
                  onPressed: () async {
                    final chosen = await getDirectoryPath();
                    if (chosen != null && mounted) await load(chosen);
                  },
                ),
                IconButton(
                  tooltip: 'Refresh local folder',
                  icon: const Icon(Icons.refresh, size: 18),
                  onPressed: refresh,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Local parent folder',
                  icon: const Icon(Icons.arrow_upward, size: 17),
                  onPressed:
                      directory.isEmpty || directory == p.dirname(directory)
                      ? null
                      : () => load(p.dirname(directory)),
                ),
                Expanded(
                  child: TextField(
                    key: const ValueKey('local-path'),
                    controller: pathController,
                    style: const TextStyle(fontSize: 12),
                    decoration: const InputDecoration(
                      hintText: 'Local path',
                      contentPadding: EdgeInsets.all(10),
                    ),
                    onSubmitted: load,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              style: const TextStyle(fontSize: 12),
              decoration: const InputDecoration(
                hintText: 'Filter local files',
                prefixIcon: Icon(Icons.search, size: 17),
                contentPadding: EdgeInsets.all(10),
              ),
              onChanged: (value) => setState(() => filter = value),
            ),
          ),
          if (loading) const LinearProgressIndicator(minHeight: 2),
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                error!,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          Expanded(
            child: visible.isEmpty
                ? Center(
                    child: Text(
                      loading
                          ? 'Loading files…'
                          : 'Drop VPS files or folders here',
                      style: const TextStyle(fontSize: 12),
                    ),
                  )
                : ListView.builder(
                    itemCount: visible.length,
                    itemBuilder: (context, index) {
                      final entry = visible[index];
                      final name = p.basename(entry.path);
                      final folder = entry is Directory;
                      final link = entry is Link;
                      Widget tile = ListTile(
                        key: ValueKey('local-entry-${entry.path}'),
                        dense: true,
                        leading: Icon(
                          folder
                              ? Icons.folder_rounded
                              : link
                              ? Icons.link
                              : Icons.insert_drive_file_outlined,
                          size: 20,
                          color: folder
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                        title: Text(
                          name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                        subtitle: link
                            ? const Text(
                                'Symbolic link • not transferred',
                                style: TextStyle(fontSize: 10),
                              )
                            : null,
                        onTap: folder ? () => load(entry.path) : null,
                        trailing: !link
                            ? const Icon(Icons.drag_indicator, size: 16)
                            : null,
                      );
                      tile = TransferDrag(
                        data: FileDrag(paths: [entry.path], local: true),
                        name: name,
                        directory: folder,
                        enabled: widget.enabled && !link,
                        child: tile,
                      );
                      if (folder) {
                        tile = TransferTarget(
                          accepts: accepts,
                          onDrop: (data) => widget.onDownload(data, entry.path),
                          label: 'Download into $name',
                          child: tile,
                        );
                      }
                      return tile;
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Text(
                  '${visible.length} items',
                  style: const TextStyle(fontSize: 10),
                ),
                const Spacer(),
                const Text(
                  'Drag to VPS to upload',
                  style: TextStyle(fontSize: 10),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
