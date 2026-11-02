// Optional real-server UI smoke test and preview renderer. See README.md.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:zeravi/data/app_store.dart';
import 'package:zeravi/data/connection.dart';
import 'package:zeravi/main.dart';

void main() {
  const fixturePath = String.fromEnvironment('SSH_FIXTURE');
  testWidgets(
    'render onboarding and exercise the connected desktop workspace',
    (tester) async {
      await tester.runAsync(() async {
        final font = File(
          '/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf',
        );
        if (await font.exists()) {
          final loader = FontLoader('sans')
            ..addFont(
              font.readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
            );
          await loader.load();
        }
        final mono = File(
          '/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf',
        );
        if (await mono.exists()) {
          final loader = FontLoader('monospace')
            ..addFont(
              mono.readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
            );
          await loader.load();
        }
        final icons = FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await icons.load();
        final store = AppStore(sqlite3.openInMemory());
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1;
        final boundaryKey = GlobalKey();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [storeProvider.overrideWith((ref) async => store)],
            child: RepaintBoundary(key: boundaryKey, child: const ZeraviApp()),
          ),
        );
        Future<void> tick() async {
          await Future<void>.delayed(const Duration(milliseconds: 120));
          await tester.pump(const Duration(milliseconds: 120));
          final errors = tester
              .widgetList<Text>(
                find.descendant(
                  of: find.byType(SnackBar),
                  matching: find.byType(Text),
                ),
              )
              .map((w) => w.data)
              .join(' ');
          if (errors.isNotEmpty && !errors.startsWith('Copied ')) fail(errors);
        }

        Future<void> until(Finder finder) async {
          for (var i = 0; i < 80 && finder.evaluate().isEmpty; i++) {
            await tick();
          }
          expect(
            finder,
            findsWidgets,
            reason: tester
                .widgetList<Text>(find.byType(Text))
                .map((widget) => widget.data)
                .join(' | '),
          );
          await tick();
        }

        Future<void> screenshot(String name) async {
          await tick();
          final boundary =
              boundaryKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final output = File('build/previews/$name.png');
          await output.parent.create(recursive: true);
          await output.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        }

        await until(find.text('Connect your first server'));
        await screenshot('zeravi-welcome');
        if (fixturePath.isNotEmpty) {
          final fixture = jsonDecode(
            await File(fixturePath).readAsString(),
          ) as Map<String, dynamic>;
          final serverPreview = await Directory(
            '${fixture['root']}/ui-${DateTime.now().microsecondsSinceEpoch}',
          ).create();
          await File('${serverPreview.path}/hello.txt')
              .writeAsString('Preview text\n');
          await Directory('${serverPreview.path}/folder').create();
          final remotePreviewPath = '/${serverPreview.path.split('/').last}';
          await tester.tap(find.byTooltip('Add server'));
          await tick();
          await tester.enterText(
            find.widgetWithText(TextFormField, 'Connection name'),
            'Local test server',
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
          await until(find.text('Connect to Local test server'));
          expect(store.connections().single.authMethod, AuthMethod.password);
          await tester.tap(find.text('Connect to Local test server'));
          await tick();
          await tester.enterText(
            find.widgetWithText(TextField, 'Password'),
            'zeravi-test-only',
          );
          await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
          await until(find.text('Trust and connect'));
          await tester.tap(find.text('Trust and connect'));
          await until(find.text('VPS FILES'));
          await tester.enterText(
            find.byKey(const ValueKey('remote-path')),
            remotePreviewPath,
          );
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await until(find.text('hello.txt'));
          final localTransferRoot = await Directory.systemTemp.createTemp(
            'zeravi-ui-drop-',
          );
          await Directory('${localTransferRoot.path}/drag-upload/nested/empty')
              .create(recursive: true);
          final uploadPath = '${localTransferRoot.path}/drag-upload';
          await File('$uploadPath/nested/note.txt')
              .writeAsString('Drag and drop roundtrip');
          await File('${localTransferRoot.path}/single.txt')
              .writeAsString('Single file upload');
          final downloadTarget = await Directory(
            '${localTransferRoot.path}/download-target',
          ).create();
          await tester.enterText(
            find.byKey(const ValueKey('local-path')),
            localTransferRoot.path,
          );
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await until(find.byKey(ValueKey('local-entry-$uploadPath')));
          Future<void> drag(Finder source, Offset target) async {
            final gesture = await tester.startGesture(tester.getCenter(source));
            await gesture.moveBy(const Offset(20, 0));
            await tick();
            await gesture.moveTo(target);
            await tick();
            await gesture.up();
            await tick();
          }

          final remoteZone = find.byKey(const ValueKey('remote-drop-zone'));
          final remoteTree = find.descendant(
            of: remoteZone,
            matching: find.text('drag-upload'),
          );
          await drag(
            find.byKey(ValueKey('local-entry-$uploadPath')),
            tester.getBottomRight(remoteZone) - const Offset(24, 24),
          );
          await until(remoteTree);
          expect(
            await File('${serverPreview.path}/drag-upload/nested/note.txt')
                .readAsString(),
            'Drag and drop roundtrip',
          );
          expect(
            await Directory('${serverPreview.path}/drag-upload/nested/empty')
                .exists(),
            isTrue,
          );
          await drag(
            find.byKey(ValueKey('remote-entry-$remotePreviewPath/drag-upload')),
            tester.getCenter(
              find.byKey(ValueKey('local-entry-${downloadTarget.path}')),
            ),
          );
          for (
            var i = 0;
            i < 80 &&
                !await File(
                  '${downloadTarget.path}/drag-upload/nested/note.txt',
                ).exists();
            i++
          ) {
            await tick();
          }
          expect(
            await File('${downloadTarget.path}/drag-upload/nested/note.txt')
                .readAsString(),
            'Drag and drop roundtrip',
          );
          expect(
            await Directory('${downloadTarget.path}/drag-upload/nested/empty')
                .exists(),
            isTrue,
          );
          await until(find.text('Copied 1 file(s) and 3 folder(s).'));
          // Cancelling an overwrite leaves the existing server file intact.
          await File('$uploadPath/nested/note.txt')
              .writeAsString('Updated drag file');
          await drag(
            find.byKey(ValueKey('local-entry-$uploadPath')),
            tester.getBottomRight(remoteZone) - const Offset(24, 24),
          );
          await until(find.text('Files already exist'));
          await tester.tap(find.text('Cancel'));
          await tick();
          expect(
            await File('${serverPreview.path}/drag-upload/nested/note.txt')
                .readAsString(),
            'Drag and drop roundtrip',
          );
          await drag(
            find.byKey(ValueKey('local-entry-$uploadPath')),
            tester.getBottomRight(remoteZone) - const Offset(24, 24),
          );
          await until(find.text('Merge and replace'));
          await tester.tap(find.text('Merge and replace'));
          for (
            var i = 0;
            i < 80 &&
                await File('${serverPreview.path}/drag-upload/nested/note.txt')
                        .readAsString() !=
                    'Updated drag file';
            i++
          ) {
            await tick();
          }
          expect(
            await File('${serverPreview.path}/drag-upload/nested/note.txt')
                .readAsString(),
            'Updated drag file',
          );
          await tick();

          // Exercise the native file-manager bridge with a file and folder in one drop.
          final nativeFolder = await Directory(
            '${localTransferRoot.path}/native-folder/empty',
          ).create(recursive: true);
          await File('${localTransferRoot.path}/native-folder/data.txt')
              .writeAsString('Native folder');
          final nativeFile = await File('${localTransferRoot.path}/native.txt')
              .writeAsString('Native file');
          final point =
              tester.getBottomRight(remoteZone) - const Offset(25, 25);
          const codec = StandardMethodCodec();
          await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
            'desktop_drop',
            codec.encodeMethodCall(MethodCall('updated', [point.dx, point.dy])),
            (_) {},
          );
          await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
            'desktop_drop',
            codec.encodeMethodCall(
              MethodCall('performOperation', [
                nativeFile.path,
                nativeFolder.parent.path,
              ]),
            ),
            (_) {},
          );
          await until(
            find.descendant(
              of: remoteZone,
              matching: find.text('native-folder'),
            ),
          );
          expect(
            await File('${serverPreview.path}/native.txt').readAsString(),
            'Native file',
          );
          expect(
            await File('${serverPreview.path}/native-folder/data.txt')
                .readAsString(),
            'Native folder',
          );
          expect(
            await Directory('${serverPreview.path}/native-folder/empty')
                .exists(),
            isTrue,
          );
          await screenshot('zeravi-transfers');
          await tester.tap(find.text('Editor'));
          await tick();
          await tester.tap(find.text('hello.txt'));
          await until(find.text('UTF-8  •  Plain text'));
          expect(tester.takeException(), isNull);
          await screenshot('zeravi-workspace');
          await tester.tap(find.byTooltip('New terminal'));
          await until(find.text('Shell 2'));
          await tester.tap(find.byTooltip('Close shell 2'));
          await tick();
          expect(find.text('Shell 2'), findsNothing);
          tester.view.physicalSize = const Size(1000, 700);
          await tick();
          expect(tester.takeException(), isNull);
          tester.view.physicalSize = const Size(1440, 900);
          await tick();
          await tester.tap(find.text('Disconnect'));
          await until(find.text('Connect to Local test server'));
          await localTransferRoot.delete(recursive: true);
          await serverPreview.delete(recursive: true);
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
