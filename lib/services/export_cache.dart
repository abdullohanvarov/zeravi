import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'file_transfer.dart';
import 'remote_session.dart';

/// Completed, private staging copies for native file-manager exports. Kept for
/// 24 hours so the destination can finish reading after the drag ends.
class ExportCache {
  ExportCache({this.directory});
  final Directory? directory;
  Future<Uri> prepare(
    RemoteSession remote,
    String path,
    void Function(String, int, int) onProgress,
  ) async {
    final root =
        directory ??
        Directory(
          p.join(
            (Platform.isLinux
                ? Directory.systemTemp.path
                : (await getTemporaryDirectory()).path),
            'zeravi-exports',
          ),
        );
    await root.create(recursive: true);
    final cutoff = DateTime.now().subtract(const Duration(hours: 24));
    await for (final entry in root.list(followLinks: false)) {
      if (entry is Directory && p.basename(entry.path).startsWith('item-')) {
        if ((await entry.stat()).modified.isBefore(cutoff)) {
          try {
            await entry.delete(recursive: true);
          } catch (_) {
            /* Busy exports can be retried next time. */
          }
        }
      }
    }
    final staging = await root.createTemp('item-');
    try {
      final transfer = FileTransfer(remote);
      final plan = await transfer.prepare(TransferDirection.download, [
        path,
      ], staging.path);
      if (plan.items.isEmpty) {
        throw StateError(
          'Symbolic links and special files cannot be exported.',
        );
      }
      await transfer.execute(
        plan,
        overwriteApproved: false,
        onProgress: onProgress,
      );
      return Uri.file(plan.items.first.destination);
    } catch (_) {
      await staging.delete(recursive: true);
      rethrow;
    }
  }
}
