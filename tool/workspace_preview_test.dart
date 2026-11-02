// UI previews use a disposable SSH server; native outgoing drag is validated at
// the export service boundary. A physical Nautilus drag needs a desktop session.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:zeravi/ui/ssh_terminal.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:zeravi/data/app_store.dart';
import 'package:zeravi/data/connection.dart';
import 'package:zeravi/main.dart';
import 'package:zeravi/ui/transfer_widgets.dart';

void main() {
  const fixturePath = String.fromEnvironment('SSH_FIXTURE');
  testWidgets(
    'server overview, native import/export, browsing preferences and editor',
    (tester) async {
      await tester.runAsync(() async {
        for (final font in {
          'sans':
              '/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf',
          'monospace':
              '/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf',
        }.entries) {
          final file = File(font.value);
          if (await file.exists()) {
            await (FontLoader(
              font.key,
            )..addFont(file.readAsBytes().then(ByteData.sublistView))).load();
          }
        }
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
        final store = AppStore(sqlite3.openInMemory());
        tester.view.physicalSize = const Size(1440, 1000);
        tester.view.devicePixelRatio = 1;
        final boundaryKey = GlobalKey();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [storeProvider.overrideWith((ref) async => store)],
            child: RepaintBoundary(
              key: boundaryKey,
              child: const ZeraviApp(nativeDragEnabled: false),
            ),
          ),
        );
        Future<void> tick() async {
          await Future<void>.delayed(const Duration(milliseconds: 120));
          await tester.pump(const Duration(milliseconds: 120));
        }

        Future<void> until(Finder finder) async {
          for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
            await tick();
          }
          expect(
            finder,
            findsWidgets,
            reason: tester
                .widgetList<Text>(find.byType(Text))
                .map((w) => w.data)
                .join(' | '),
          );
          await tick();
        }

        Future<void> shot(String name) async {
          final ctx = find.byType(Scaffold).first.evaluate().first;
          ScaffoldMessenger.of(ctx).clearSnackBars();
          await tick();
          await tick();
          final boundary =
              boundaryKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('build/previews/$name.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        }

        await until(find.text('Connect your first server'));
        await shot('zeravi-welcome');
        if (fixturePath.isNotEmpty) {
          final fixture = jsonDecode(
            await File(fixturePath).readAsString(),
          ) as Map<String, dynamic>;
          final remoteRoot = await Directory(
            '${fixture['root']}/admin-ui-${DateTime.now().microsecondsSinceEpoch}',
          ).create();
          final remotePath = '/${remoteRoot.path.split('/').last}';
          await Directory('${remoteRoot.path}/folder').create();
          await File('${remoteRoot.path}/hello.txt')
              .writeAsString('Hello from Zeravi\n');
          await File('${remoteRoot.path}/.env')
              .writeAsString('TEST_ONLY=yes\n');
          await tester.tap(find.byTooltip('Add server'));
          await tick();
          await tester.enterText(
            find.widgetWithText(TextFormField, 'Connection name'),
            'Development server',
          );
          await tester.enterText(
            find.widgetWithText(TextFormField, 'Hostname or IP'),
            '127.0.0.1',
          );
          await tester.enterText(
            find.widgetWithText(TextFormField, 'Port'),
            '${fixture['port']}',
          );
          await tester.enterText(
            find.widgetWithText(TextFormField, 'Username'),
            'tester',
          );
          await tester.tap(find.text('Password'));
          await tick();
          await tester.tap(find.text('Save connection'));
          await until(find.text('Connect to Development server'));
          expect(store.connections().single.authMethod, AuthMethod.password);
          await tester.tap(find.text('Connect to Development server'));
          await tick();
          await tester.enterText(
            find.widgetWithText(TextField, 'Password'),
            'zeravi-test-only',
          );
          await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
          await until(find.text('Trust and connect'));
          await tester.tap(find.text('Trust and connect'));
          await until(find.text('zeravi-fixture'));
          await tester.tap(find.byTooltip('Hide terminal panel'));
          await tick();
          await tester.tap(find.byType(DropdownButton<int>));
          await tick();
          await tester.tap(find.text('Every 2s').last);
          await tick();
          await until(find.text('30.0%'));
          await shot('zeravi-overview');
          expect(tester.takeException(), isNull);
          await tester.tap(find.byTooltip('Pause monitoring'));
          await tick();
          expect(find.text('Monitoring paused'), findsOneWidget);
          await tester.tap(find.text('Files'));
          await tick();
          expect(find.text('LOCAL FILES'), findsNothing);
          await tester.enterText(
            find.byKey(const ValueKey('remote-path')),
            remotePath,
          );
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await until(find.text('hello.txt'));
          expect(find.text('.env'), findsNothing);
          await tester.tap(find.byTooltip('Switch to grid view'));
          await tick();
          expect(find.byKey(const ValueKey('remote-grid')), findsOneWidget);
          expect(store.setting('file_view'), contains('"gridView":true'));
          final folderEntry = find.byKey(
            ValueKey('remote-entry-$remotePath/folder'),
          );
          await tester.tap(folderEntry, buttons: kSecondaryMouseButton);
          await tick();
          await tick();
          await tick();
          await tester.tap(find.text('Open in terminal'));
          await until(find.byKey(const ValueKey('terminal-tab-2')));
          expect(
            tester
                .widgetList<SshTerminal>(
                  find.byType(SshTerminal, skipOffstage: false),
                )
                .any((w) => w.initialDirectory == '$remotePath/folder'),
            isTrue,
          );
          final rightPane = find.byKey(const ValueKey('right-terminal-pane'));
          expect(
            tester.getTopLeft(rightPane).dx,
            greaterThan(
              tester
                  .getTopRight(find.byKey(const ValueKey('remote-drop-zone')))
                  .dx,
            ),
          );
          final beforeWidth = tester.getSize(rightPane).width;
          await tester.drag(
            find.byKey(const ValueKey('terminal-resize-handle')),
            const Offset(60, 0),
          );
          await tick();
          expect(tester.getSize(rightPane).width, lessThan(beforeWidth));
          await tester.tap(find.byTooltip('Maximize terminal'));
          await tick();
          expect(tester.takeException(), isNull);
          expect(tester.getSize(rightPane).width, greaterThan(beforeWidth));
          await tester.tap(find.byTooltip('Restore terminal size'));
          await tick();
          await tester.tap(find.byTooltip('Collapse connections (Ctrl+B)'));
          await tick();
          expect(find.byTooltip('Expand connections (Ctrl+B)'), findsOneWidget);
          expect(
            store.setting('file_view'),
            contains('"connectionsCollapsed":true'),
          );
          await tester.tap(find.byTooltip('Expand connections (Ctrl+B)'));
          await tick();
          await tester.tap(find.byTooltip('Close shell 2'));
          await tick();

          await tester.tap(find.byTooltip('Show dot files (Ctrl+H)'));
          await until(find.text('.env'));
          await tester.tap(find.byTooltip('Sort and view options'));
          await tick();
          await tick();
          await tick();
          await tick();
          await tester.tap(
            find.ancestor(
              of: find.text('Sort by size'),
              matching: find.byType(CheckedPopupMenuItem<String>),
            ),
          );
          await tick();
          await tick();
          await tick();
          await tick();
          await tick();
          expect(store.setting('file_view'), contains('"sort":"size"'));
          final localRoot = await Directory.systemTemp.createTemp(
            'zeravi-native-ui-',
          );
          await Directory('${localRoot.path}/incoming/nested/empty')
              .create(recursive: true);
          await File('${localRoot.path}/incoming/nested/note.txt')
              .writeAsString('Native transfer roundtrip');
          final region = find.byKey(const ValueKey('remote-drop-zone'));
          final point = tester.getBottomRight(region) - const Offset(28, 25);
          const codec = StandardMethodCodec();
          await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
            'desktop_drop',
            codec.encodeMethodCall(MethodCall('updated', [point.dx, point.dy])),
            (_) {},
          );
          await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
            'desktop_drop',
            codec.encodeMethodCall(
              MethodCall('performOperation', ['${localRoot.path}/incoming']),
            ),
            (_) {},
          );
          await until(find.text('incoming'));
          final intoFolder = await File('${localRoot.path}/into-folder.txt')
              .writeAsString('Folder target');
          final folderPoint = tester.getCenter(
            find.byKey(ValueKey('remote-entry-$remotePath/folder')),
          );
          await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
            'desktop_drop',
            codec.encodeMethodCall(
              MethodCall('updated', [folderPoint.dx, folderPoint.dy]),
            ),
            (_) {},
          );
          await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
            'desktop_drop',
            codec.encodeMethodCall(
              MethodCall('performOperation', [intoFolder.path]),
            ),
            (_) {},
          );
          for (
            var i = 0;
            i < 100 &&
                !await File('${remoteRoot.path}/folder/into-folder.txt')
                    .exists();
            i++
          ) {
            await tick();
          }
          expect(
            await File('${remoteRoot.path}/folder/into-folder.txt')
                .readAsString(),
            'Folder target',
          );
          await tick();

          expect(
            await File('${remoteRoot.path}/incoming/nested/note.txt')
                .readAsString(),
            'Native transfer roundtrip',
          );
          // Invoke the exact lazy provider used by native file-manager exports.
          final nativeWidget = tester
              .widgetList<NativeExportDrag>(find.byType(NativeExportDrag))
              .firstWhere((w) => w.name == 'incoming');
          final uri = await nativeWidget.prepare();
          expect(
            await File('${uri.toFilePath()}/nested/note.txt').readAsString(),
            'Native transfer roundtrip',
          );
          expect(
            await Directory('${uri.toFilePath()}/nested/empty').exists(),
            isTrue,
          );
          await File.fromUri(uri).parent.delete(recursive: true);
          await shot('zeravi-files');
          await tester.tap(find.byTooltip('Switch to list view'));
          await tick();
          expect(find.byKey(const ValueKey('remote-list')), findsOneWidget);
          await tester.tap(find.text('hello.txt'));
          await until(find.text('UTF-8  •  Plain text'));
          if (find.byTooltip('Show terminal panel').evaluate().isNotEmpty) {
            await tester.tap(find.byTooltip('Show terminal panel'));
            await tick();
          }
          await tester.tap(find.byTooltip('New terminal'));
          await until(find.byKey(const ValueKey('terminal-tab-3')));
          await tester.tap(find.byTooltip('Close shell 3'));
          await tick();
          await shot('zeravi-workspace');
          tester.view.physicalSize = const Size(1000, 700);
          await tick();
          expect(tester.takeException(), isNull);
          await tester.tap(find.text('Overview'));
          await tick();
          expect(tester.takeException(), isNull);
          tester.view.physicalSize = const Size(1440, 1000);
          await tick();
          await tester.tap(find.text('Disconnect'));
          await until(find.text('Connect to Development server'));
          await localRoot.delete(recursive: true);
          await remoteRoot.delete(recursive: true);
        }
        await tester.pumpWidget(const SizedBox());
        await tick();
        store.close();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        expect(tester.takeException(), isNull);
      });
    },
  );
}
