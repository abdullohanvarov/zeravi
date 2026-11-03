import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

class BotHostingException implements Exception {
  const BotHostingException(this.message);
  final String message;
  @override
  String toString() => message;
}

class BotProject {
  const BotProject({
    required this.path,
    required this.size,
    required this.modified,
    required this.files,
    required this.roots,
    required this.expandedSize,
  });
  final String path;
  final int size, modified, expandedSize;
  final List<String> files, roots;
  String suggestedEntry(String root) {
    final prefix = root.isEmpty ? '' : '$root/';
    final scripts =
        files
            .where((name) => name.startsWith(prefix) && name.endsWith('.py'))
            .map((name) => name.substring(prefix.length))
            .toList()
          ..sort();
    for (final entry in ['main.py', 'bot.py', 'app.py']) {
      if (scripts.contains(entry)) return entry;
    }
    return scripts.firstOrNull ?? 'main.py';
  }

  bool containsEntry(String root, String entry) =>
      files.contains(root.isEmpty ? entry : '$root/$entry');
  static Future<BotProject> inspect(String path) =>
      Isolate.run(() => inspectBotProject(path));
}

String validateBotRelativePath(String value, {bool empty = false}) {
  if (empty && value.isEmpty) return value;
  if (value.isEmpty ||
      value.startsWith('/') ||
      RegExp(r'^[A-Za-z]:').hasMatch(value) ||
      value.contains(RegExp(r'[\\\x00\r\n]')) ||
      value
          .split('/')
          .any((part) => part.isEmpty || part == '.' || part == '..')) {
    throw const BotHostingException(
      'Project paths must stay inside the project folder.',
    );
  }
  return value;
}

BotProject inspectBotProject(String path) {
  final file = File(path);
  final stat = file.statSync();
  if (stat.type != FileSystemEntityType.file || stat.size > 100 * 1024 * 1024) {
    throw const BotHostingException('Choose a ZIP file up to 100 MiB.');
  }
  try {
    final directory = ZipDirectory();
    final input = InputMemoryStream(file.readAsBytesSync());
    final names = <String>{}, files = <String>[], roots = <String>{};
    var total = 0, count = 0;
    for (final header in directory.headers(input, files: false, verify: true)) {
      if (++count > 10000) {
        throw const BotHostingException(
          'The ZIP contains more than 10,000 entries.',
        );
      }
      final name = validateBotRelativePath(
        header.filename.replaceFirst(RegExp(r'/$'), ''),
      );
      if (!names.add(name)) {
        throw const BotHostingException('The ZIP contains duplicate paths.');
      }
      final kind = (header.externalFileAttributes >> 16) & 0xf000;
      if ((header.generalPurposeBitFlag & 1) != 0 ||
          ![0, 0x4000, 0x8000].contains(kind)) {
        throw const BotHostingException(
          'Encrypted ZIPs, symbolic links and special files are not supported.',
        );
      }
      total += header.uncompressedSize;
      if (total > 1024 * 1024 * 1024 ||
          header.uncompressedSize > 256 * 1024 * 1024) {
        throw const BotHostingException(
          'The project exceeds the extracted size limits (1 GiB total, 256 MiB per file).',
        );
      }
      if (name
          .split('/')
          .any(
            (part) => [
              '.venv',
              'venv',
              '.git',
              '__pycache__',
              '__MACOSX',
              '.DS_Store',
            ].contains(part),
          )) {
        continue;
      }
      if (!header.filename.endsWith('/') && kind != 0x4000) {
        files.add(name);
        if (p.posix.basename(name) == 'requirements.txt') {
          final parent = p.posix.dirname(name);
          roots.add(parent == '.' ? '' : parent);
        }
      }
    }
    if (roots.isEmpty) {
      throw const BotHostingException(
        'Add requirements.txt to the project before creating the ZIP.',
      );
    }
    final sorted = roots.toList()..sort();
    if (sorted.remove('')) sorted.insert(0, '');
    return BotProject(
      path: path,
      size: stat.size,
      modified: stat.modified.millisecondsSinceEpoch,
      files: files,
      roots: sorted,
      expandedSize: total,
    );
  } on BotHostingException {
    rethrow;
  } catch (_) {
    throw const BotHostingException(
      'This ZIP could not be read. Create a fresh unencrypted ZIP and try again.',
    );
  }
}

Map<String, String> parseBotEnvironment(String text) {
  final result = <String, String>{};
  for (var line in text.split('\n')) {
    line = line.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final equals = line.indexOf('=');
    if (equals <= 0 ||
        !RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$')
            .hasMatch(line.substring(0, equals))) {
      throw const BotHostingException(
        'Use NAME=value for each environment variable.',
      );
    }
    var value = line.substring(equals + 1);
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1);
    }
    result[line.substring(0, equals)] = value;
  }
  return result;
}

class HostedBot {
  HostedBot(this.data);
  final Map<String, dynamic> data;
  String get id => data['id'] as String;
  String get name => data['name'] as String;
  String get path => data['path'] as String;
  String get entrypoint => data['entrypoint'] as String;
  String get state => data['state'] as String? ?? 'unknown';
  String get subState => data['subState'] as String? ?? '';
  String get current => data['current'] as String? ?? '';
  String? get previous => data['previous'] as String?;
  String get restart => data['restart'] as String? ?? 'on-failure';
  bool get autostart => data['autostart'] != false;
  List<String> get envKeys => (data['envKeys'] as List? ?? []).cast<String>();
  List<String> get persistent =>
      (data['persistent'] as List? ?? ['data', 'uploads', 'storage'])
          .cast<String>();
  bool get running => state == 'active';
  String get statusLabel => switch (state) {
    'active' => 'Running',
    'inactive' => 'Stopped',
    'failed' => 'Failed',
    'activating' => 'Starting / restarting',
    _ => 'Unknown',
  };
}
