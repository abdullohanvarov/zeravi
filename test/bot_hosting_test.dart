import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeravi/data/bot_project.dart';
import 'package:zeravi/ui/bot_hosting_panel.dart';

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('zeravi-bot-test-'));
  tearDown(() => temp.deleteSync(recursive: true));
  BotProject zip(Map<String, String> files) {
    final archive = Archive();
    for (final entry in files.entries) {
      archive.add(ArchiveFile.string(entry.key, entry.value));
    }
    final file = File('${temp.path}/project.zip')
      ..writeAsBytesSync(ZipEncoder().encode(archive));
    return inspectBotProject(file.path);
  }

  test(
    'inspect nested project and choose main entry without extracting code',
    () {
      final project = zip({
        'project/requirements.txt': '',
        'project/main.py': 'raise Exception("never run locally")',
        'project/.venv/ignored.py': '',
      });
      expect(project.roots, ['project']);
      expect(project.suggestedEntry('project'), 'main.py');
      expect(project.files, isNot(contains('project/.venv/ignored.py')));
      expect(Directory('${temp.path}/project').existsSync(), isFalse);
    },
  );
  test('reject missing requirements, traversal, and non-Python entry', () {
    expect(() => zip({'main.py': ''}), throwsA(isA<BotHostingException>()));
    expect(
      () => zip({'requirements.txt': '', '../outside': ''}),
      throwsA(isA<BotHostingException>()),
    );
    for (final value in [
      '/etc/passwd',
      '../file',
      'a/../file',
      'C:/file',
      'a\\b',
      'a\nfile',
    ]) {
      expect(
        () => validateBotRelativePath(value),
        throwsA(isA<BotHostingException>()),
      );
    }
  });
  test('environment parser preserves equals and accepts quoted values', () {
    expect(
      parseBotEnvironment(
        '# test\nBOT_TOKEN=abc=def\nEMPTY=\nNAME="hello world"',
      ),
      {'BOT_TOKEN': 'abc=def', 'EMPTY': '', 'NAME': 'hello world'},
    );
    expect(
      () => parseBotEnvironment('not a key=value'),
      throwsA(isA<BotHostingException>()),
    );
  });
  testWidgets(
    'deployment dialog validates script and keeps existing secrets private',
    (tester) async {
      final project = zip({'requirements.txt': '', 'main.py': ''});
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => BotSettingsDialog(project: project),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('Deploy Python bot'), findsOneWidget);
      expect(find.text('main.py'), findsOneWidget);
      expect(find.text('BOT_TOKEN=your-token'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Python entry point'),
        'missing.py',
      );
      await tester.tap(find.text('Deploy'));
      await tester.pumpAndSettle();
      expect(
        find.text('That entry point is not in the selected project folder.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
