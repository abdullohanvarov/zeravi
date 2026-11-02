import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:zeravi/data/app_store.dart';
import 'package:zeravi/data/connection.dart';
import 'package:zeravi/services/remote_session.dart';

void main() {
  const fixturePath = String.fromEnvironment('SSH_FIXTURE');
  test(
    'real SSH/SFTP trust, authentication, transfers, editor conflicts and shell',
    () async {
      final fixture = jsonDecode(
        await File(fixturePath).readAsString(),
      ) as Map<String, dynamic>;
      final root = Directory(fixture['root'] as String);
      await File('${root.path}/hello.txt')
          .writeAsString('Hello from the test server!\n');
      final previous = Directory('${root.path}/created');
      if (await previous.exists()) await previous.delete(recursive: true);
      final store = AppStore(sqlite3.openInMemory());
      addTearDown(store.close);
      final profile = ServerConnection(
        id: 'integration',
        name: 'Fixture',
        host: '127.0.0.1',
        username: 'tester',
        port: fixture['port'] as int,
        authMethod: AuthMethod.password,
      );
      var trustPrompts = 0;
      final session = await RemoteSession.connect(
        profile,
        store,
        'zeravi-test-only',
        (type, fingerprint) async {
          trustPrompts++;
          expect(fingerprint, fixture['fingerprint']);
          return true;
        },
      );
      addTearDown(session.close);
      expect(trustPrompts, 1);
      final entries = await session.list('/');
      expect(entries.first.attr.isDirectory, isTrue);
      expect(entries.map((entry) => entry.filename), contains('hello.txt'));
      expect(
        await session.readText('/hello.txt'),
        'Hello from the test server!\n',
      );
      await expectLater(session.readText('/binary.bin'), throwsStateError);
      await session.saveText(
        '/hello.txt',
        'Hello from the test server!\n',
        'Short\n',
      );
      expect(await session.readText('/hello.txt'), 'Short\n');
      await expectLater(
        session.saveText('/hello.txt', 'stale content', 'oops'),
        throwsStateError,
      );
      expect(await session.readText('/hello.txt'), 'Short\n');
      final local = await Directory.systemTemp.createTemp('zeravi-transfer-');
      addTearDown(() => local.delete(recursive: true));
      final source = File('${local.path}/upload.txt');
      await source.writeAsString('Transfer 🌿\n' * 10000);
      var uploaded = 0;
      await session.upload(
        source.path,
        '/uploaded.txt',
        (bytes) => uploaded = bytes,
      );
      expect(uploaded, await source.length());
      final destination = File('${local.path}/download.txt');
      await session.download('/uploaded.txt', destination.path, (_) {});
      expect(await destination.readAsBytes(), await source.readAsBytes());
      await session.sftp.mkdir('/created');
      await session.sftp.rename('/uploaded.txt', '/created/renamed.txt');
      expect((await session.list('/created')).single.filename, 'renamed.txt');
      final shell = await session.client.shell(pty: const SSHPtyConfig());
      final output = shell.stdout
          .cast<List<int>>()
          .transform(utf8.decoder)
          .join();
      shell.stdin.add(Uint8List.fromList(utf8.encode('ping\nexit\n')));
      expect(await output, contains('echo: ping'));
      await shell.done;
      session.close();
      await session.client.done;
      final keyProfile = ServerConnection(
        id: 'key',
        name: 'Key fixture',
        host: '127.0.0.1',
        username: 'tester',
        port: profile.port,
        keyPath: fixture['keyPath'] as String,
      );
      final keySession = await RemoteSession.connect(keyProfile, store, '', (
        _,
        _,
      ) async {
        fail('A known host must not ask for trust again');
      });
      expect(await keySession.readText('/hello.txt'), 'Short\n');
      keySession.close();
      await keySession.client.done;
      final changedStore = AppStore(sqlite3.openInMemory());
      addTearDown(changedStore.close);
      changedStore.trust(
        '127.0.0.1',
        profile.port,
        'ssh-ed25519',
        'SHA256:changed',
      );
      await expectLater(
        RemoteSession.connect(profile, changedStore, 'zeravi-test-only', (
          _,
          _,
        ) async {
          fail('A changed host key must never be accepted as a new key');
        }),
        throwsA(anything),
      );
      final rejectedStore = AppStore(sqlite3.openInMemory());
      addTearDown(rejectedStore.close);
      await expectLater(
        RemoteSession.connect(
          profile,
          rejectedStore,
          'zeravi-test-only',
          (_, _) async => false,
        ),
        throwsA(anything),
      );
      expect(rejectedStore.trustedKey('127.0.0.1', profile.port), isNull);
      await expectLater(
        RemoteSession.connect(
          profile,
          store,
          'incorrect',
          (_, _) async => false,
        ),
        throwsA(anything),
      );
    },
    skip: fixturePath.isEmpty
        ? 'Start tool/test_ssh_server.py and pass --dart-define=SSH_FIXTURE=<path>'
        : false,
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
