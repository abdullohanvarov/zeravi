import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/app_store.dart';
import '../data/connection.dart';

class VSCodeLaunchException implements Exception {
  const VSCodeLaunchException(this.message);
  final String message;
  @override
  String toString() => message;
}

typedef CodeCommandRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

List<String> vscodeArguments(
  String alias,
  String remotePath, {
  required bool directory,
}) {
  if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]*$').hasMatch(alias)) {
    throw const VSCodeLaunchException(
      'The SSH alias contains unsupported characters. Edit the connection and use a simple Host name.',
    );
  }
  if (!remotePath.startsWith('/') || remotePath.contains('\u0000')) {
    throw const VSCodeLaunchException(
      'Choose an absolute remote file or folder path.',
    );
  }
  final uri = Uri(
    scheme: 'vscode-remote',
    host: 'ssh-remote+$alias',
    path: remotePath,
  );
  return [directory ? '--folder-uri' : '--file-uri', uri.toString()];
}

String _sshQuote(String value) {
  if (value.contains(RegExp(r'[\r\n\x00]'))) {
    throw const VSCodeLaunchException(
      'The saved SSH connection contains an invalid line break. Edit the connection first.',
    );
  }
  return '"${value.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';
}

Future<void> _privateWrite(File target, String contents) async {
  final staging = await target.parent.createTemp('.zeravi-ssh-');
  final temporary = File(p.join(staging.path, 'config'));
  try {
    await temporary.create();
    if (Platform.isLinux || Platform.isMacOS) {
      final result = await Process.run('chmod', ['600', temporary.path]);
      if (result.exitCode != 0) {
        throw const VSCodeLaunchException(
          'Could not secure the generated SSH configuration.',
        );
      }
    }
    await temporary.writeAsString(contents, flush: true);
    await temporary.rename(target.path);
  } finally {
    await staging.delete(recursive: true);
  }
}

/// Keep user-defined aliases unchanged. Profiles without an alias get a managed
/// entry containing metadata and a key path, never a password or key contents.
Future<String> ensureVSCodeHost(
  ServerConnection connection, {
  String? sshDirectory,
}) async {
  final provided = connection.vscodeAlias.trim();
  if (provided.isNotEmpty) {
    vscodeArguments(provided, '/', directory: true);
    return provided;
  }
  if (validateHost(connection.host) != null ||
      connection.username.isEmpty ||
      connection.port < 1 ||
      connection.port > 65535) {
    throw const VSCodeLaunchException(
      'The saved connection is incomplete. Check the host, username and port.',
    );
  }
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (sshDirectory == null && home == null) {
    throw const VSCodeLaunchException(
      'Your local home directory could not be found.',
    );
  }
  final directory = Directory(sshDirectory ?? p.join(home!, '.ssh'));
  final existed = await directory.exists();
  await directory.create(recursive: true);
  if (!existed && (Platform.isLinux || Platform.isMacOS)) {
    await Process.run('chmod', ['700', directory.path]);
  }
  final id = connection.id.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
  if (id.isEmpty) {
    throw const VSCodeLaunchException(
      'Save this server connection again before opening VS Code.',
    );
  }
  final alias = 'zeravi-$id';
  final managed = File(p.join(directory.path, 'zeravi.conf'));
  const header = '# Managed by Zeravi. Connection metadata only.\n';
  var contents = await managed.exists() ? await managed.readAsString() : header;
  if (!contents.startsWith(header)) {
    throw const VSCodeLaunchException(
      'The reserved ~/.ssh/zeravi.conf file is not managed by Zeravi. Set an existing VS Code SSH alias in the connection instead.',
    );
  }
  final begin = '# BEGIN $alias', end = '# END $alias';
  final block = StringBuffer(
    '$begin\nHost $alias\n  HostName ${_sshQuote(connection.host)}\n  User ${_sshQuote(connection.username)}\n  Port ${connection.port}\n',
  );
  if (connection.authMethod == AuthMethod.privateKey &&
      connection.keyPath.isNotEmpty) {
    block.write(
      '  IdentityFile ${_sshQuote(expandHome(connection.keyPath))}\n  IdentitiesOnly yes\n',
    );
  }
  block.write('$end\nHost *\n');
  final pattern = RegExp(
    '${RegExp.escape(begin)}\\n[\\s\\S]*?${RegExp.escape(end)}\\nHost \\*\\n',
  );
  if (pattern.hasMatch(contents)) {
    contents = contents.replaceFirst(pattern, block.toString());
  } else {
    contents += '\n$block';
  }
  await _privateWrite(managed, contents);

  var config = File(p.join(directory.path, 'config'));
  // Preserve a user's config symlink rather than replacing it with a regular file.
  if (await FileSystemEntity.type(config.path, followLinks: false) ==
      FileSystemEntityType.link) {
    config = File(await config.resolveSymbolicLinks());
  }
  final original = await config.exists() ? await config.readAsString() : '';
  final include = 'Include ${_sshQuote(managed.absolute.path)}';
  if (!original.split('\n').contains(include)) {
    if (original.isNotEmpty) {
      final backup = File(p.join(directory.path, 'config.zeravi-backup'));
      if (!await backup.exists()) await _privateWrite(backup, original);
    }
    await _privateWrite(config, '$include\n$original');
  }
  return alias;
}

Future<void> openConnectionInVSCode(
  ServerConnection connection,
  String path, {
  required bool directory,
  String? sshDirectory,
  CodeCommandRunner? run,
}) async {
  final runner =
      run ??
      (String executable, List<String> args) => Process.run(executable, args);
  try {
    final check = await runner('code', [
      '--list-extensions',
    ]).timeout(const Duration(seconds: 20));
    final installed = check.stdout
        .toString()
        .split(RegExp(r'[\r\n]+'))
        .any(
          (line) => line.trim().toLowerCase() == 'ms-vscode-remote.remote-ssh',
        );
    if (!installed) {
      throw const VSCodeLaunchException(
        'Install “Remote - SSH” in your local VS Code, then try again.',
      );
    }
    final alias = await ensureVSCodeHost(
      connection,
      sshDirectory: sshDirectory,
    );
    final result = await runner('code', [
      '--new-window',
      ...vscodeArguments(alias, path, directory: directory),
    ]).timeout(const Duration(seconds: 20));
    if (result.exitCode != 0) {
      final detail = result.stderr.toString().trim();
      throw VSCodeLaunchException(
        'VS Code could not open this remote path.${detail.isEmpty ? '' : ' $detail'}',
      );
    }
  } on VSCodeLaunchException {
    rethrow;
  } on ProcessException {
    throw const VSCodeLaunchException(
      'VS Code’s “code” command was not found. Install VS Code or add it to PATH.',
    );
  } on TimeoutException {
    throw const VSCodeLaunchException(
      'VS Code took too long to respond. Open it locally once, then try again.',
    );
  } on FileSystemException {
    throw const VSCodeLaunchException(
      'Zeravi could not update your local SSH configuration. Check ~/.ssh permissions or set an existing VS Code SSH alias in the connection.',
    );
  }
}
