import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:path/path.dart' as p;

import 'remote_session.dart';

enum TransferDirection { upload, download }

enum _Kind { missing, file, directory, unsupported }

class TransferItem {
  TransferItem(this.source, this.destination, this.directory, this.size);
  final String source;
  final String destination;
  final bool directory;
  final int size;
  bool existed = false;
}

class TransferPlan {
  TransferPlan(this.direction, this.destinationRoot);
  final TransferDirection direction;
  final String destinationRoot;
  final List<TransferItem> items = [];
  int skipped = 0;
  int get folders => items.where((item) => item.directory).length;
  int get files => items.where((item) => !item.directory).length;
  int get bytes => items.fold(0, (sum, item) => sum + item.size);
  int get overwrites =>
      items.where((item) => !item.directory && item.existed).length;
  int get merges =>
      items.where((item) => item.directory && item.existed).length;
}

/// Copy-only transfers. Links and special files are never traversed. Each file
/// is staged beside its destination so a failed stream leaves the original intact.
class FileTransfer {
  FileTransfer(this.remote);
  final RemoteSession remote;

  Future<TransferPlan> prepare(
    TransferDirection direction,
    List<String> sources,
    String destination,
  ) async {
    final plan = TransferPlan(direction, destination);
    if (await _destinationKind(plan, destination) != _Kind.directory) {
      throw StateError(
        'Choose an existing destination folder, not a symbolic link.',
      );
    }
    final seen = <String>{};
    for (final source in sources.toSet()) {
      final name = direction == TransferDirection.upload
          ? p.basename(source)
          : p.posix.basename(source);
      if (!seen.add(name)) {
        throw StateError('Multiple dropped items have the same name: $name');
      }
      await _collect(
        plan,
        source,
        safeTransferChild(
          destination,
          name,
          remote: direction == TransferDirection.upload,
        ),
      );
    }
    // Preflight the entire tree before writing anything.
    for (final item in plan.items) {
      final kind = await _destinationKind(plan, item.destination);
      if (kind == _Kind.unsupported ||
          (item.directory && kind == _Kind.file) ||
          (!item.directory && kind == _Kind.directory)) {
        throw StateError(
          'Cannot copy over a different item type or symbolic link: ${item.destination}',
        );
      }
      item.existed = kind != _Kind.missing;
    }
    return plan;
  }

  Future<void> _collect(
    TransferPlan plan,
    String source,
    String destination, [
    int depth = 0,
  ]) async {
    if (depth > 128) {
      throw StateError('This folder tree is too deep to transfer.');
    }
    final upload = plan.direction == TransferDirection.upload;
    final kind = upload ? await _localKind(source) : await _remoteKind(source);
    if (kind == _Kind.missing) {
      throw StateError('The source no longer exists: $source');
    }
    if (kind == _Kind.unsupported) {
      plan.skipped++;
      return;
    }
    if (kind == _Kind.file) {
      final size = upload
          ? await File(source).length()
          : (await remote.sftp.stat(source, followLink: false)).size ?? 0;
      plan.items.add(TransferItem(source, destination, false, size));
      return;
    }
    plan.items.add(TransferItem(source, destination, true, 0));
    if (upload) {
      await for (final child in Directory(source).list(followLinks: false)) {
        await _collect(
          plan,
          child.path,
          safeTransferChild(destination, p.basename(child.path), remote: true),
          depth + 1,
        );
      }
    } else {
      for (final child in await remote.list(source)) {
        await _collect(
          plan,
          safeTransferChild(source, child.filename, remote: true),
          safeTransferChild(destination, child.filename, remote: false),
          depth + 1,
        );
      }
    }
  }

  Future<void> execute(
    TransferPlan plan, {
    required bool overwriteApproved,
    required void Function(String name, int completedBytes, int totalBytes)
    onProgress,
  }) async {
    if (plan.overwrites > 0 && !overwriteApproved) {
      throw StateError('Replacing files requires confirmation.');
    }
    final upload = plan.direction == TransferDirection.upload;
    var completed = 0;
    for (final item in plan.items) {
      await _checkParents(plan, item.destination);
      final kind = await _destinationKind(plan, item.destination);
      if (kind == _Kind.unsupported ||
          (item.directory && kind == _Kind.file) ||
          (!item.directory && kind == _Kind.directory)) {
        throw StateError(
          'The destination changed during transfer: ${item.destination}',
        );
      }
      if (!item.directory &&
          kind == _Kind.file &&
          (!item.existed || !overwriteApproved)) {
        throw StateError(
          'A new file appeared at ${item.destination}. Drop again to confirm replacing it.',
        );
      }
      final sourceKind = upload
          ? await _localKind(item.source)
          : await _remoteKind(item.source);
      if (sourceKind != (item.directory ? _Kind.directory : _Kind.file)) {
        throw StateError('The source changed during transfer: ${item.source}');
      }
      onProgress(item.destination, completed, plan.bytes);
      if (item.directory) {
        if (kind == _Kind.missing) {
          if (upload) {
            await remote.sftp.mkdir(item.destination);
          } else {
            await Directory(item.destination).create();
          }
        }
      } else {
        var actualBytes = 0;
        void update(int bytes) {
          actualBytes = bytes;
          onProgress(item.destination, completed + bytes, plan.bytes);
        }

        if (upload) {
          await _upload(item, update);
        } else {
          await _download(item, update);
        }
        completed += actualBytes;
      }
    }
    onProgress('Complete', completed, plan.bytes);
  }

  Future<void> _checkParents(TransferPlan plan, String destination) async {
    final context = plan.direction == TransferDirection.upload
        ? p.posix
        : p.context;
    var current = context.dirname(destination);
    while (true) {
      if (await _destinationKind(plan, current) != _Kind.directory) {
        throw StateError(
          'Destination folder is missing or is a symbolic link: $current',
        );
      }
      if (current == plan.destinationRoot) break;
      if (!context.isWithin(plan.destinationRoot, current)) {
        throw StateError('Destination escaped the selected folder.');
      }
      current = context.dirname(current);
    }
  }

  Future<void> _upload(TransferItem item, void Function(int) progress) async {
    final suffix = List.generate(
      12,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final temp = p.posix.join(
      p.posix.dirname(item.destination),
      '.zeravi-$suffix.part',
    );
    final file = await remote.sftp.open(
      temp,
      mode:
          SftpFileOpenMode.write |
          SftpFileOpenMode.create |
          SftpFileOpenMode.exclusive,
    );
    var committed = false;
    try {
      await file.write(
        File(item.source).openRead().map(Uint8List.fromList),
        onProgress: progress,
      );
      await file.close();
      // On servers lacking POSIX rename, replacing an existing file may fail.
      // Keep the original rather than deleting it to force a replacement.
      await remote.sftp.rename(temp, item.destination);
      committed = true;
    } finally {
      await file.close();
      if (!committed) {
        try {
          await remote.sftp.remove(temp);
        } catch (_) {
          /* Connection may already be gone. */
        }
      }
    }
  }

  Future<void> _download(TransferItem item, void Function(int) progress) async {
    final staging = await Directory(p.dirname(item.destination))
        .createTemp('.zeravi-transfer-');
    try {
      final temporary = File(p.join(staging.path, 'content'));
      await remote.download(item.source, temporary.path, progress);
      await temporary.rename(item.destination);
    } finally {
      await staging.delete(recursive: true);
    }
  }

  Future<_Kind> _destinationKind(TransferPlan plan, String path) =>
      plan.direction == TransferDirection.upload
      ? _remoteKind(path)
      : _localKind(path);

  Future<_Kind> _localKind(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return _Kind.missing;
    if (type == FileSystemEntityType.directory) return _Kind.directory;
    if (type == FileSystemEntityType.file) return _Kind.file;
    return _Kind.unsupported;
  }

  Future<_Kind> _remoteKind(String path) async {
    try {
      final attrs = await remote.sftp.stat(path, followLink: false);
      if (attrs.isDirectory) return _Kind.directory;
      if (attrs.isFile) return _Kind.file;
      return _Kind.unsupported;
    } on SftpStatusError catch (error) {
      if (error.code == SftpStatusCode.noSuchFile) return _Kind.missing;
      rethrow;
    }
  }
}

String safeTransferChild(
  String directory,
  String name, {
  required bool remote,
}) {
  if (name.isEmpty ||
      name == '.' ||
      name == '..' ||
      name.contains('/') ||
      name.contains('\\') ||
      name.contains('\u0000')) {
    throw StateError('Unsafe file name received: $name');
  }
  return remote ? p.posix.join(directory, name) : p.join(directory, name);
}
