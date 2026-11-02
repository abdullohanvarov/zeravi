import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../data/app_store.dart';
import '../data/connection.dart';

typedef TrustHost = Future<bool> Function(String type, String fingerprint);

class RemoteSession {
  RemoteSession._(this.connection, this.client, this.sftp);
  final ServerConnection connection;
  final SSHClient client;
  final SftpClient sftp;

  static Future<RemoteSession> connect(
    ServerConnection connection,
    AppStore store,
    String secret,
    TrustHost trustHost,
  ) async {
    List<SSHKeyPair>? keys;
    if (connection.authMethod == AuthMethod.privateKey) {
      keys = SSHKeyPair.fromPem(
        await File(expandHome(connection.keyPath)).readAsString(),
        secret.isEmpty ? null : secret,
      );
    }
    final socket = await SSHSocket.connect(
      connection.host,
      connection.port,
      timeout: const Duration(seconds: 15),
    );
    final client = SSHClient(
      socket,
      username: connection.username,
      identities: keys,
      onPasswordRequest: connection.authMethod == AuthMethod.password
          ? () => secret
          : null,
      keepAliveInterval: const Duration(seconds: 20),
      onVerifyHostKey: (type, bytes) async {
        final fingerprint = utf8.decode(bytes);
        final known = store.trustedKey(connection.host, connection.port);
        if (known != null) {
          if (known != '$type $fingerprint') {
            throw StateError(
              'The server host key changed. Verify the server identity before connecting.',
            );
          }
          return true;
        }
        if (!await trustHost(type, fingerprint)) return false;
        store.trust(connection.host, connection.port, type, fingerprint);
        return true;
      },
    );
    // Consume transport errors even if authentication or SFTP setup fails first.
    client.done.ignore();
    try {
      await client.authenticated;
      final sftp = await client.sftp();
      return RemoteSession._(connection, client, sftp);
    } catch (_) {
      client.close();
      rethrow;
    }
  }

  Future<List<SftpName>> list(String path) async {
    final entries = (await sftp.listdir(path))
        .where((entry) => entry.filename != '.' && entry.filename != '..')
        .toList();
    entries.sort((a, b) {
      if (a.attr.isDirectory != b.attr.isDirectory) {
        return a.attr.isDirectory ? -1 : 1;
      }
      return a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
    });
    return entries;
  }

  static const maxEditorBytes = 1024 * 1024;

  Future<String> readText(String path) async {
    final file = await sftp.open(path);
    try {
      final attrs = await file.stat();
      if (!attrs.isFile || (attrs.size ?? 0) > maxEditorBytes) {
        throw StateError(
          'The editor supports regular text files up to 1 MiB. Open this file in VS Code.',
        );
      }
      final bytes = await file.readBytes(length: maxEditorBytes + 1);
      if (bytes.length > maxEditorBytes || bytes.contains(0)) {
        throw StateError('This file is too large or contains binary data.');
      }
      return utf8.decode(bytes);
    } finally {
      await file.close();
    }
  }

  Future<void> saveText(String path, String original, String updated) async {
    if (utf8.encode(updated).length > maxEditorBytes) {
      throw StateError('The editor supports files up to 1 MiB.');
    }
    if (await readText(path) != original) {
      throw StateError(
        'This file changed on the server. Reopen it before saving to avoid overwriting someone else’s changes.',
      );
    }
    final file = await sftp.open(path, mode: SftpFileOpenMode.write);
    try {
      final bytes = Uint8List.fromList(utf8.encode(updated));
      await file.writeBytes(bytes);
      await file.setStat(SftpFileAttrs(size: bytes.length));
    } finally {
      await file.close();
    }
  }

  Future<void> upload(
    String localPath,
    String remotePath,
    void Function(int) progress,
  ) async {
    final file = await sftp.open(
      remotePath,
      mode:
          SftpFileOpenMode.write |
          SftpFileOpenMode.create |
          SftpFileOpenMode.truncate,
    );
    try {
      await file.write(
        File(localPath).openRead().map(Uint8List.fromList),
        onProgress: progress,
      );
    } finally {
      await file.close();
    }
  }

  Future<void> download(
    String remotePath,
    String localPath,
    void Function(int) progress,
  ) async {
    final remote = await sftp.open(remotePath);
    final local = File(localPath).openWrite();
    try {
      await local.addStream(remote.read(onProgress: progress));
      await local.flush();
    } finally {
      await local.close();
      await remote.close();
    }
  }

  void close() => client.close();
}
