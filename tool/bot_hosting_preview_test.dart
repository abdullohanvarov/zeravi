// Real SSH/SFTP with fake server OS commands; no bot dependencies are executed.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:zeravi/data/app_store.dart';
import 'package:zeravi/data/bot_project.dart';
import 'package:zeravi/data/connection.dart';
import 'package:zeravi/services/bot_hosting.dart';
import 'package:zeravi/services/remote_session.dart';
import 'package:zeravi/ui/bot_hosting_panel.dart';

void main() {
  const fixturePath = String.fromEnvironment('SSH_FIXTURE');
  testWidgets('hosting dashboard, stop/start, logs and settings over SSH', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final fixture = jsonDecode(
        await File(fixturePath).readAsString(),
      ) as Map<String, dynamic>;
      final store = AppStore(sqlite3.openInMemory());
      final remote = await RemoteSession.connect(
        ServerConnection(
          id: 'hosting-ui',
          name: 'Hosting UI',
          host: '127.0.0.1',
          port: fixture['port'] as int,
          username: 'tester',
          authMethod: AuthMethod.password,
        ),
        store,
        'zeravi-test-only',
        (_, _) async => true,
      );
      final host = BotHostingController(BotHostingService(remote));
      // The disposable fixture may be reused after an interrupted preview.
      final old = await host.service.invoke({'action': 'list'});
      for (final bot in old['bots'] as List) {
        await host.service.invoke({
          'action': 'remove',
          'id': bot['id'],
          'deleteData': true,
        });
      }
      final temp = await Directory.systemTemp.createTemp('hosting-ui-');
      try {
        for (final font in {
          'sans':
              '/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf',
          'monospace':
              '/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf',
        }.entries) {
          await (FontLoader(font.key)..addFont(
                File(font.value).readAsBytes().then(ByteData.sublistView),
              ))
              .load();
        }
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
        final zip = File('${temp.path}/telegram-bot.zip')
          ..writeAsBytesSync(
            ZipEncoder().encode(
              Archive()
                ..add(ArchiveFile.string('requirements.txt', ''))
                ..add(ArchiveFile.string('main.py', 'print("Fixture only")')),
            ),
          );
        final project = await BotProject.inspect(zip.path);
        await host.deploy(project, {
          'name': 'Customer support bot',
          'environment': {'BOT_TOKEN': 'fixture-token'},
        });
        tester.view.physicalSize = const Size(1200, 900);
        tester.view.devicePixelRatio = 1;
        final boundaryKey = GlobalKey();
        String? openedProject;
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundaryKey,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(
                fontFamily: 'sans',
                brightness: Brightness.dark,
                colorSchemeSeed: Colors.teal,
                useMaterial3: true,
              ),
              home: Scaffold(
                body: BotHostingPanel(
                  controller: host,
                  onOpenFiles: (path) => openedProject = path,
                  onOpenTerminal: (_) {},
                ),
              ),
            ),
          ),
        );
        Future<void> tick() async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await tester.pump(const Duration(milliseconds: 100));
        }

        Future<void> until(Finder finder) async {
          for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
            await tick();
          }
          expect(finder, findsWidgets);
          await tick();
        }

        Future<void> shot(String name) async {
          await tick();
          final boundary =
              boundaryKey.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('build/previews/$name.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        }

        await until(find.text('Customer support bot'));
        await shot('zeravi-bot-hosting');
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Stop'));
        await until(find.text('Stopped'));
        await tester.tap(find.text('Start'));
        await until(find.text('Running'));
        await tester.tap(find.text('Logs'));
        await until(find.text('Bot started\n'));
        await shot('zeravi-bot-logs');
        await tester.tap(find.text('Close'));
        await tick();
        await tick();
        await tester.tap(find.byTooltip('Manage Customer support bot'));
        await tick();
        await tick();
        await tester.tap(find.text('Open project in Files'));
        await tick();
        await tick();
        expect(openedProject, contains('/telegrambots/'));
        expect(openedProject, endsWith('/current/app'));
        await tester.tap(find.byTooltip('Manage Customer support bot'));
        await tick();
        await tick();
        await tester.tap(find.text('Settings & environment'));
        await until(find.text('Bot settings'));
        expect(find.text('Stored keys: BOT_TOKEN'), findsOneWidget);
        expect(find.textContaining('fixture-token'), findsNothing);
        await shot('zeravi-bot-settings');
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Bot name'),
          'Updated support bot',
        );
        await tester.tap(find.text('Save settings'));
        for (var i = 0; i < 100 && (host.busy || host.refreshing); i++) {
          await tick();
        }
        await until(find.text('Updated support bot'));
        expect(host.error, isEmpty);
        expect(tester.takeException(), isNull);
        final id = host.bots.single.id;
        expect(await host.action('remove', id, {'deleteData': true}), true);
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        host.dispose();
        remote.close();
        store.close();
        await temp.delete(recursive: true);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    });
  });
}
