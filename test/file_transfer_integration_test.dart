import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:zeravi/data/app_store.dart';
import 'package:zeravi/data/connection.dart';
import 'package:zeravi/services/file_transfer.dart';
import 'package:zeravi/services/export_cache.dart';
import 'package:zeravi/services/server_monitor.dart';
import 'package:zeravi/services/remote_session.dart';

void main() {
  const fixturePath = String.fromEnvironment('SSH_FIXTURE');
  test(
    'recursive copies, empty folders, merges, links and collision protection',
    () async {
      final fixture = jsonDecode(
        await File(fixturePath).readAsString(),
      ) as Map<String, dynamic>;
      final local = await Directory.systemTemp.createTemp('zeravi-tree-');
      addTearDown(() => local.delete(recursive: true));
      final store = AppStore(sqlite3.openInMemory());
      addTearDown(store.close);
      final session = await RemoteSession.connect(
        ServerConnection(
          id: 'tree',
          name: 'Tree tests',
          host: '127.0.0.1',
          username: 'tester',
          port: fixture['port'] as int,
          authMethod: AuthMethod.password,
        ),
        store,
        'zeravi-test-only',
        (_, _) async => true,
      );
      addTearDown(session.close);
      final remoteRoot = '/tree-${DateTime.now().microsecondsSinceEpoch}';
      await session.sftp.mkdir(remoteRoot);
      final source = await Directory('${local.path}/project 🌿').create();
      await Directory('${source.path}/nested/empty').create(recursive: true);
      await File('${source.path}/nested/binary.bin')
          .writeAsBytes([0, 255, 1, 127]);
      await File('${source.path}/read me.txt').writeAsString('Original\n');
      await File('${source.path}/.hidden').writeAsString('Hidden file');
      await Link('${source.path}/loop').create(source.path);
      final transfer = FileTransfer(session);
      final plan = await transfer.prepare(TransferDirection.upload, [
        source.path,
      ], remoteRoot);
      expect(plan.files, 3);
      expect(plan.skipped, 1);
      expect(plan.overwrites, 0);
      expect(plan.items.where((item) => item.directory).length, 3);
      var completed = 0;
      await transfer.execute(
        plan,
        overwriteApproved: false,
        onProgress: (_, bytes, _) => completed = bytes,
      );
      expect(completed, plan.bytes);
      expect(
        await File('${source.path}/read me.txt').readAsString(),
        'Original\n',
      );
      expect(
        await session.readText('$remoteRoot/project 🌿/read me.txt'),
        'Original\n',
      );
      expect(
        await session.list('$remoteRoot/project 🌿/nested/empty'),
        isEmpty,
      );
      expect(
        (await session.list('$remoteRoot/project 🌿'))
            .map((item) => item.filename),
        isNot(contains('loop')),
      );

      final downloadRoot = await Directory('${local.path}/downloads').create();
      final download = await transfer.prepare(TransferDirection.download, [
        '$remoteRoot/project 🌿',
      ], downloadRoot.path);
      await transfer.execute(
        download,
        overwriteApproved: false,
        onProgress: (_, _, _) {},
      );
      expect(
        await File('${downloadRoot.path}/project 🌿/nested/binary.bin')
            .readAsBytes(),
        [0, 255, 1, 127],
      );
      expect(
        await Directory('${downloadRoot.path}/project 🌿/nested/empty')
            .exists(),
        isTrue,
      );
      expect(
        await File('${downloadRoot.path}/project 🌿/.hidden').readAsString(),
        'Hidden file',
      );

      await File('${source.path}/read me.txt').writeAsString('Replacement\n');
      final replace = await transfer.prepare(TransferDirection.upload, [
        source.path,
      ], remoteRoot);
      expect(replace.overwrites, 3);
      expect(replace.merges, 3);
      await expectLater(
        transfer.execute(
          replace,
          overwriteApproved: false,
          onProgress: (_, _, _) {},
        ),
        throwsStateError,
      );
      expect(
        await session.readText('$remoteRoot/project 🌿/read me.txt'),
        'Original\n',
      );
      await transfer.execute(
        replace,
        overwriteApproved: true,
        onProgress: (_, _, _) {},
      );
      expect(
        await session.readText('$remoteRoot/project 🌿/read me.txt'),
        'Replacement\n',
      );

      final keep = File('${downloadRoot.path}/project 🌿/keep.txt');
      await keep.writeAsString('Keep this');
      final mergeDownload = await transfer.prepare(TransferDirection.download, [
        '$remoteRoot/project 🌿',
      ], downloadRoot.path);
      await transfer.execute(
        mergeDownload,
        overwriteApproved: true,
        onProgress: (_, _, _) {},
      );
      expect(await keep.readAsString(), 'Keep this');
      expect(
        await File('${downloadRoot.path}/project 🌿/read me.txt')
            .readAsString(),
        'Replacement\n',
      );
      expect(
        await Directory(downloadRoot.path)
            .list(recursive: true)
            .where((item) => item.path.contains('.zeravi-transfer-'))
            .isEmpty,
        isTrue,
      );
      expect(
        (await session.list('$remoteRoot/project 🌿'))
            .where((item) => item.filename.contains('.part')),
        isEmpty,
      );

      // Staging names stay short even when the original filename is near the filesystem limit.
      final longName = '${'x' * 240}.txt';
      final longFile = await File('${local.path}/$longName')
          .writeAsString('Long name');
      final longPlan = await transfer.prepare(TransferDirection.upload, [
        longFile.path,
      ], remoteRoot);
      await transfer.execute(
        longPlan,
        overwriteApproved: false,
        onProgress: (_, _, _) {},
      );
      expect(await session.readText('$remoteRoot/$longName'), 'Long name');

      // Native drag exports publish a URI only after the entire folder is readable locally.
      final exportRoot = await Directory('${local.path}/exports').create();
      final exported = await ExportCache(directory: exportRoot)
          .prepare(session, '$remoteRoot/project 🌿', (_, _, _) {});
      expect(exported.scheme, 'file');
      expect(
        await File('${exported.toFilePath()}/nested/binary.bin').readAsBytes(),
        [0, 255, 1, 127],
      );
      expect(
        await Directory('${exported.toFilePath()}/nested/empty').exists(),
        isTrue,
      );
      expect(
        await File('${exported.toFilePath()}/read me.txt').readAsString(),
        'Replacement\n',
      );
      final metrics = await readServerSnapshot(session.client);
      expect(metrics.hostname, 'zeravi-fixture');
      expect(metrics.memoryTotal, 4194304 * 1024);
      expect(metrics.disks.first.mount, '/');
      expect(metrics.processes.first.command, 'python3');

      // A file appearing after preflight is not silently overwritten.
      final single = await File('${local.path}/new.txt')
          .writeAsString('New file');
      final race = await transfer.prepare(TransferDirection.upload, [
        single.path,
      ], remoteRoot);
      await session.upload(single.path, '$remoteRoot/new.txt', (_) {});
      await expectLater(
        transfer.execute(
          race,
          overwriteApproved: false,
          onProgress: (_, _, _) {},
        ),
        throwsStateError,
      );

      // Reject incompatible destination types before copying any part of a tree.
      final conflictRoot = await Directory('${local.path}/conflict').create();
      await File('${conflictRoot.path}/project 🌿')
          .writeAsString('Do not replace');
      await expectLater(
        transfer.prepare(TransferDirection.download, [
          '$remoteRoot/project 🌿',
        ], conflictRoot.path),
        throwsStateError,
      );
      expect(
        await File('${conflictRoot.path}/project 🌿').readAsString(),
        'Do not replace',
      );

      // Refuse a destination symlink, including a link nested inside a merge.
      final linkedRoot = await Directory('${local.path}/linked').create();
      await Link('${linkedRoot.path}/project 🌿').create(source.path);
      await expectLater(
        transfer.prepare(TransferDirection.download, [
          '$remoteRoot/project 🌿',
        ], linkedRoot.path),
        throwsStateError,
      );

      // Never follow links from a VPS folder into another server location.
      await session.sftp.link(
        '$remoteRoot/remote-link',
        '$remoteRoot/project 🌿',
      );
      final skipped = await transfer.prepare(TransferDirection.download, [
        '$remoteRoot/remote-link',
      ], downloadRoot.path);
      expect(skipped.items, isEmpty);
      expect(skipped.skipped, 1);
    },
    skip: fixturePath.isEmpty ? 'Requires the disposable SSH fixture' : false,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('untrusted remote file names cannot escape the destination', () {
    for (final name in [
      '',
      '.',
      '..',
      '../outside',
      '/absolute',
      'bad\\name',
      'bad\u0000name',
    ]) {
      expect(
        () => safeTransferChild('/tmp/target', name, remote: false),
        throwsStateError,
      );
    }
    expect(
      safeTransferChild('/target', 'normal 🌿.txt', remote: true),
      '/target/normal 🌿.txt',
    );
  });
}
