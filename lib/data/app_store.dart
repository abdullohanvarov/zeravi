import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'connection.dart';

class AppStore {
  AppStore(this.database) {
    database.execute(
      'CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    database.execute('''CREATE TABLE IF NOT EXISTS connections (
      id TEXT PRIMARY KEY, name TEXT NOT NULL, host TEXT NOT NULL,
      username TEXT NOT NULL, port INTEGER NOT NULL, auth_method TEXT NOT NULL,
      key_path TEXT NOT NULL, vscode_alias TEXT NOT NULL)''');
    database.execute('''CREATE TABLE IF NOT EXISTS trusted_hosts (
      host TEXT NOT NULL, port INTEGER NOT NULL, key_type TEXT NOT NULL,
      fingerprint TEXT NOT NULL, PRIMARY KEY(host, port))''');
  }

  final Database database;

  static Future<AppStore> open() async {
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    return AppStore(sqlite3.open(p.join(directory.path, 'zeravi.sqlite')));
  }

  List<ServerConnection> connections() => database
      .select('SELECT * FROM connections ORDER BY name COLLATE NOCASE')
      .map(ServerConnection.fromMap)
      .toList();

  void save(ServerConnection connection) {
    final map = connection.toMap();
    database.execute('''INSERT OR REPLACE INTO connections
      (id, name, host, username, port, auth_method, key_path, vscode_alias)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)''', map.values.toList());
  }

  void delete(String id) =>
      database.execute('DELETE FROM connections WHERE id = ?', [id]);

  String? trustedKey(String host, int port) {
    final rows = database.select(
      'SELECT key_type, fingerprint FROM trusted_hosts WHERE host = ? AND port = ?',
      [host.toLowerCase(), port],
    );
    return rows.isEmpty
        ? null
        : '${rows.first['key_type']} ${rows.first['fingerprint']}';
  }

  void trust(String host, int port, String type, String fingerprint) =>
      database.execute(
        'INSERT INTO trusted_hosts (host, port, key_type, fingerprint) VALUES (?, ?, ?, ?)',
        [host.toLowerCase(), port, type, fingerprint],
      );

  String? setting(String key) {
    final result = database.select('SELECT value FROM settings WHERE key = ?', [
      key,
    ]);
    return result.isEmpty ? null : result.first['value'] as String;
  }

  void setSetting(String key, String value) => database.execute(
    'INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)',
    [key, value],
  );

  void close() => database.close();
}

String expandHome(String path) {
  if (path == '~' || path.startsWith('~/')) {
    final home = Platform.environment['HOME'];
    if (home == null) throw StateError('Home directory is unavailable');
    return path == '~' ? home : p.join(home, path.substring(2));
  }
  return path;
}
