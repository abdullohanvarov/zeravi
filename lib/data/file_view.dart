import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:path/path.dart' as p;

import 'app_store.dart';

enum FileSort { name, size, modified, type }

class FileViewSettings {
  FileSort sort = FileSort.name;
  bool descending = false,
      showHidden = false,
      foldersFirst = true,
      compact = false,
      showTerminal = true;
  int pollSeconds = 5;

  FileViewSettings();
  factory FileViewSettings.load(AppStore store) {
    final settings = FileViewSettings();
    try {
      final raw = store.setting('file_view');
      if (raw == null) return settings;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      settings.sort = FileSort.values.byName(map['sort'] as String? ?? 'name');
      settings.descending = map['descending'] == true;
      settings.showHidden = map['showHidden'] == true;
      settings.foldersFirst = map['foldersFirst'] != false;
      settings.compact = map['compact'] == true;
      settings.showTerminal = map['showTerminal'] != false;
      final poll = map['pollSeconds'];
      if ([2, 5, 10, 30].contains(poll)) settings.pollSeconds = poll as int;
    } catch (_) {
      /* Invalid preferences fall back to defaults. */
    }
    return settings;
  }
  void save(AppStore store) => store.setSetting(
    'file_view',
    jsonEncode({
      'sort': sort.name,
      'descending': descending,
      'showHidden': showHidden,
      'foldersFirst': foldersFirst,
      'compact': compact,
      'showTerminal': showTerminal,
      'pollSeconds': pollSeconds,
    }),
  );
  List<SftpName> visible(List<SftpName> entries, String filter) {
    final result = entries
        .where(
          (e) =>
              (showHidden || !e.filename.startsWith('.')) &&
              e.filename.toLowerCase().contains(filter.toLowerCase()),
        )
        .toList();
    result.sort((a, b) {
      if (foldersFirst && a.attr.isDirectory != b.attr.isDirectory) {
        return a.attr.isDirectory ? -1 : 1;
      }
      int order;
      switch (sort) {
        case FileSort.name:
          order = a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
        case FileSort.size:
          order = (a.attr.size ?? 0).compareTo(b.attr.size ?? 0);
        case FileSort.modified:
          order = (a.attr.modifyTime ?? 0).compareTo(b.attr.modifyTime ?? 0);
        case FileSort.type:
          order = fileType(a).compareTo(fileType(b));
      }
      if (order == 0) {
        order = a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
      }
      return descending ? -order : order;
    });
    return result;
  }
}

String fileType(SftpName entry) => entry.attr.isDirectory
    ? 'folder'
    : p.posix.extension(entry.filename).toLowerCase();
