import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:zeravi/data/app_store.dart';
import 'package:zeravi/main.dart';

void main() {
  late AppStore store;
  setUp(() => store = AppStore(sqlite3.openInMemory()));
  tearDown(() => store.close());

  Future<void> launch(
    WidgetTester tester, {
    Size size = const Size(1440, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [storeProvider.overrideWith((ref) async => store)],
        child: const ZeraviApp(nativeDragEnabled: false),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('empty workspace shows onboarding and theme can be changed', (
    tester,
  ) async {
    await launch(tester);
    expect(find.text('Your servers.\nA familiar workspace.'), findsOneWidget);
    expect(find.text('Connect your first server'), findsOneWidget);
    await tester.tap(find.byTooltip('Toggle light / dark theme'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'connection form validates, persists and supports editing a profile',
    (tester) async {
      await launch(tester);
      await tester.tap(find.text('Connect your first server'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save connection'));
      await tester.pumpAndSettle();
      expect(find.text('Give this server a name'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Connection name'),
        'Dev machine',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Hostname or IP'),
        '127.0.0.1',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Private key file'),
        '~/.ssh/id_ed25519',
      );
      await tester.tap(find.text('Save connection'));
      await tester.pumpAndSettle();
      expect(store.connections().single.name, 'Dev machine');
      expect(store.connections().single.keyPath, '~/.ssh/id_ed25519');
      expect(find.text('Dev machine'), findsOneWidget);
      await tester.tap(find.byTooltip('Connection actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit connection'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Connection name'),
        'Development',
      );
      await tester.tap(find.text('Save connection'));
      await tester.pumpAndSettle();
      expect(store.connections().single.name, 'Development');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('onboarding and connection dialog fit smaller desktop windows', (
    tester,
  ) async {
    await launch(tester, size: const Size(800, 600));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Add server'));
    await tester.pumpAndSettle();
    expect(find.text('Add a server'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
