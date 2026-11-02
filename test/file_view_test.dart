import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:zeravi/data/app_store.dart';
import 'package:zeravi/data/file_view.dart';

SftpName entry(
  String name, {
  int size = 0,
  int modified = 0,
  bool folder = false,
}) => SftpName(
  filename: name,
  longname: name,
  attr: SftpFileAttrs(
    size: size,
    modifyTime: modified,
    mode: SftpFileMode.value(folder ? 0x4000 | 493 : 0x8000 | 420),
  ),
);

void main() {
  test('hidden filtering, sorting directions and folder grouping compose', () {
    final settings = FileViewSettings();
    final files = [
      entry('.env'),
      entry('z.txt', size: 30),
      entry('a.txt', size: 10),
      entry('folder', folder: true),
    ];
    expect(settings.visible(files, '').map((e) => e.filename), [
      'folder',
      'a.txt',
      'z.txt',
    ]);
    settings.sort = FileSort.size;
    settings.descending = true;
    expect(settings.visible(files, '').map((e) => e.filename), [
      'folder',
      'z.txt',
      'a.txt',
    ]);
    settings.showHidden = true;
    expect(settings.visible(files, '.ENV').single.filename, '.env');
    settings.foldersFirst = false;
    expect(settings.visible(files, '').first.filename, 'z.txt');
  });
  test(
    'view preferences roundtrip and malformed settings fall back safely',
    () {
      final store = AppStore(sqlite3.openInMemory());
      addTearDown(store.close);
      final settings = FileViewSettings()
        ..sort = FileSort.modified
        ..showHidden = true
        ..compact = true
        ..showTerminal = false
        ..pollSeconds = 10
        ..gridView = true
        ..connectionsCollapsed = true
        ..terminalWidth = 500
        ..explorerWidth = 280;
      settings.save(store);
      final loaded = FileViewSettings.load(store);
      expect(loaded.sort, FileSort.modified);
      expect(loaded.showHidden, isTrue);
      expect(loaded.compact, isTrue);
      expect(loaded.showTerminal, isFalse);
      expect(loaded.pollSeconds, 10);
      expect(loaded.gridView, isTrue);
      expect(loaded.connectionsCollapsed, isTrue);
      expect(loaded.terminalWidth, 500);
      expect(loaded.explorerWidth, 280);
      store.setSetting('file_view', 'invalid json');
      expect(FileViewSettings.load(store).sort, FileSort.name);
      store.setSetting('theme', 'light');
      expect(store.setting('theme'), 'light');
    },
  );
}
