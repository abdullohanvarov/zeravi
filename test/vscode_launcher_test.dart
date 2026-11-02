import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeravi/data/connection.dart';
import 'package:zeravi/services/vscode_launcher.dart';

void main() {
  late Directory root;
  setUp(
    () async =>
        root = await Directory.systemTemp.createTemp('zeravi-code-test-'),
  );
  tearDown(() async => root.delete(recursive: true));
  test('blank alias works with the saved host, port and key without changing existing aliases', () async {
    final config = File('${root.path}/config');
    const original =
        'Host personal\n  HostName personal.example\n\nHost *\n  ServerAliveInterval 30\n';
    await config.writeAsString(original);
    const connection = ServerConnection(
      id: 'unit-1',
      name: 'Unit',
      host: 'server.example',
      username: 'dev',
      port: 2222,
      keyPath: '/tmp/key with spaces',
    );
    final calls = <List<String>>[];
    await openConnectionInVSCode(
      connection,
      '/home/dev/a b/#file?.txt',
      directory: false,
      sshDirectory: root.path,
      run: (executable, args) async {
        calls.add([executable, ...args]);
        return ProcessResult(
          1,
          0,
          args.contains('--list-extensions')
              ? 'ms-vscode-remote.remote-ssh\n'
              : '',
          '',
        );
      },
    );
    expect(calls.last, contains('--new-window'));
    expect(calls.last, contains('--file-uri'));
    expect(
      Uri.decodeComponent(Uri.parse(calls.last.last).path),
      '/home/dev/a b/#file?.txt',
    );
    expect(
      await File('${root.path}/config.zeravi-backup').readAsString(),
      original,
    );
    expect(await config.readAsString(), endsWith(original));
    final resolved = await Process.run('ssh', [
      '-G',
      '-F',
      config.path,
      'zeravi-unit-1',
    ]);
    expect(resolved.exitCode, 0);
    expect(resolved.stdout, contains('hostname server.example'));
    expect(resolved.stdout, contains('user dev'));
    expect(resolved.stdout, contains('port 2222'));
    expect(resolved.stdout, contains('identityfile /tmp/key with spaces'));
    expect(resolved.stdout, contains('serveraliveinterval 30'));
    final personal = await Process.run('ssh', [
      '-G',
      '-F',
      config.path,
      'personal',
    ]);
    expect(personal.stdout, contains('hostname personal.example'));
    await ensureVSCodeHost(connection, sshDirectory: root.path);
    expect(
      'Host zeravi-unit-1'
          .allMatches(await File('${root.path}/zeravi.conf').readAsString())
          .length,
      1,
    );
    expect('Include '.allMatches(await config.readAsString()).length, 1);
  });
  test('manual aliases bypass generated configuration and missing extensions produce a friendly message', () async {
    const connection = ServerConnection(
      id: 'manual',
      name: 'Manual',
      host: 'example.test',
      username: 'dev',
      vscodeAlias: 'my-server',
    );
    expect(
      await ensureVSCodeHost(connection, sshDirectory: root.path),
      'my-server',
    );
    expect(await root.list().isEmpty, isTrue);
    await expectLater(
      openConnectionInVSCode(
        connection,
        '/tmp',
        directory: true,
        sshDirectory: root.path,
        run: (_, _) async => ProcessResult(1, 0, '', ''),
      ),
      throwsA(
        isA<VSCodeLaunchException>().having(
          (e) => e.message,
          'message',
          contains('Remote - SSH'),
        ),
      ),
    );
    expect(await root.list().isEmpty, isTrue);
  });
  test(
    'generated config rejects directive injection and never persists passwords',
    () async {
      const invalid = ServerConnection(
        id: 'bad',
        name: 'Bad',
        host: 'example.test',
        username: 'dev\nProxyCommand bad',
      );
      await expectLater(
        ensureVSCodeHost(invalid, sshDirectory: root.path),
        throwsA(isA<VSCodeLaunchException>()),
      );
      const password = ServerConnection(
        id: 'password',
        name: 'Password',
        host: 'example.test',
        username: 'dev',
        authMethod: AuthMethod.password,
      );
      await ensureVSCodeHost(password, sshDirectory: root.path);
      final contents = await File('${root.path}/zeravi.conf').readAsString();
      expect(contents, isNot(contains('IdentityFile')));
      expect(contents, isNot(contains('StrictHostKeyChecking')));
      expect(contents, isNot(contains('Password ')));
    },
  );
}
