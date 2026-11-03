import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:zeravi/data/app_store.dart';
import 'package:zeravi/data/bot_project.dart';
import 'package:zeravi/data/connection.dart';
import 'package:zeravi/services/bot_hosting.dart';
import 'package:zeravi/services/remote_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const fixturePath = String.fromEnvironment('SSH_FIXTURE');
  test(
    'ZIP uploads over SFTP and hosting JSON lifecycle runs over SSH stdin',
    () async {
      final fixture = jsonDecode(
        await File(fixturePath).readAsString(),
      ) as Map<String, dynamic>;
      final store = AppStore(sqlite3.openInMemory());
      addTearDown(store.close);
      final session = await RemoteSession.connect(
        ServerConnection(
          id: 'hosting-test',
          name: 'Hosting',
          host: '127.0.0.1',
          port: fixture['port'] as int,
          username: 'tester',
          authMethod: AuthMethod.password,
        ),
        store,
        'zeravi-test-only',
        (_, _) async => true,
      );
      addTearDown(session.close);
      final service = BotHostingService(session);
      final doctor = await service.invoke({'action': 'list'});
      expect((doctor['doctor'] as Map)['ready'], true);
      final temp = await Directory.systemTemp.createTemp('hosting-zip-');
      addTearDown(() => temp.delete(recursive: true));
      final archive = Archive()
        ..add(ArchiveFile.string('project/requirements.txt', ''))
        ..add(ArchiveFile.string('project/main.py', 'print("test")'));
      final file = File('${temp.path}/project.zip');
      await file.writeAsBytes(ZipEncoder().encode(archive));
      final project = await BotProject.inspect(file.path);
      final events = <String>[];
      final bot = await service.deploy(project, {
        'projectRoot': 'project',
        'entrypoint': 'main.py',
        'name': 'Integration test bot',
        'environment': {'BOT_TOKEN': 'fixture-token'},
      }, event: (_, text) => events.add(text));
      expect(bot.running, true);
      expect(bot.envKeys, ['BOT_TOKEN']);
      expect(jsonEncode(bot.data), isNot(contains('fixture-token')));
      expect(events, contains('Installing requirements.txt'));
      final stopped = await service.invoke({
        'action': 'control',
        'id': bot.id,
        'verb': 'stop',
      });
      expect(stopped['state'], 'inactive');
      final updated = await service.deploy(project, {
        'id': bot.id,
        'projectRoot': 'project',
      });
      expect(updated.previous, bot.current);
      final rolledBack = await service.invoke({
        'action': 'rollback',
        'id': bot.id,
      });
      expect(rolledBack['current'], bot.current);
      final removed = await service.invoke({
        'action': 'remove',
        'id': bot.id,
        'deleteData': true,
      });
      expect(removed['removed'], true);
      expect(
        (await Directory(fixture['root'] as String).list().toList()).where(
          (f) => f.path.split('/').last.startsWith('.zeravi-upload-'),
        ),
        isEmpty,
      );
      await expectLater(
        service.invoke({
          'action': 'control',
          'id': '../invalid',
          'verb': 'stop',
        }),
        throwsA(isA<BotHostingException>()),
      );
    },
    skip: fixturePath.isEmpty ? 'Run with the disposable SSH fixture.' : false,
  );
}
