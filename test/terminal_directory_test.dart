import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeravi/ui/ssh_terminal.dart';

void main() {
  test('folder terminal commands quote spaces, apostrophes and shell operators as a single path', () async {
    final root = await Directory.systemTemp.createTemp('zeravi-terminal-');
    addTearDown(() => root.delete(recursive: true));
    final directory = await Directory("${root.path}/a folder's name; echo nope")
        .create();
    final command = terminalDirectoryCommand(directory.path)
        .replaceAll('\r', '\n');
    final result = await Process.run('sh', ['-c', '${command}pwd']);
    expect(result.exitCode, 0);
    expect(result.stdout.toString().trim(), directory.path);
    expect(() => terminalDirectoryCommand('relative'), throwsArgumentError);
  });
}
