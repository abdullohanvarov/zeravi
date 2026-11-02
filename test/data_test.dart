import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:zeravi/data/app_store.dart';
import 'package:zeravi/data/connection.dart';
import 'package:zeravi/services/remote_session.dart';

void main() {
  test('profile roundtrip, update and removal preserve metadata only', () {
    final store = AppStore(sqlite3.openInMemory());
    addTearDown(store.close);
    const profile = ServerConnection(
      id: '1',
      name: 'Test',
      host: 'localhost',
      username: 'dev',
      port: 2222,
      keyPath: '/keys/test',
    );
    store.save(profile);
    expect(store.connections().single.toMap(), profile.toMap());
    expect(profile.toMap().keys, isNot(contains('password')));
    expect(profile.toMap().keys, isNot(contains('passphrase')));
    store.save(
      const ServerConnection(
        id: '1',
        name: 'Changed',
        host: 'localhost',
        username: 'dev',
      ),
    );
    expect(store.connections().single.name, 'Changed');
    store.delete('1');
    expect(store.connections(), isEmpty);
  });

  test('host trust is bound to normalized host and port and cannot silently replace a key', () {
    final store = AppStore(sqlite3.openInMemory());
    addTearDown(store.close);
    store.trust('Example.COM', 22, 'ssh-ed25519', 'SHA256:abc');
    expect(store.trustedKey('example.com', 22), 'ssh-ed25519 SHA256:abc');
    expect(store.trustedKey('example.com', 2222), isNull);
    expect(
      () => store.trust('example.com', 22, 'ssh-ed25519', 'SHA256:other'),
      throwsA(isA<SqliteException>()),
    );
  });

  test('VS Code arguments encode paths without interpreting shell syntax', () {
    final args = vscodeArguments(
      'dev-box',
      '/home/dev/a b/#notes?.txt',
      directory: false,
    );
    expect(args.first, '--file-uri');
    expect(
      Uri.decodeComponent(Uri.parse(args.last).path),
      '/home/dev/a b/#notes?.txt',
    );
    expect(Uri.parse(args.last).host, 'ssh-remote+dev-box');
    expect(
      () => vscodeArguments('--help', '/tmp', directory: true),
      throwsStateError,
    );
    expect(
      () => vscodeArguments('dev;echo bad', '/tmp', directory: true),
      throwsStateError,
    );
    expect(
      () => vscodeArguments('dev', 'relative', directory: true),
      throwsArgumentError,
    );
  });

  test(
    'input validation rejects invalid ports, host URLs and unsafe file names',
    () {
      expect(validatePort('65536'), isNotNull);
      expect(validatePort('0'), isNotNull);
      expect(validatePort('22'), isNull);
      expect(validateHost('ssh://host'), isNotNull);
      expect(validateHost('::1'), isNull);
      for (final name in ['..', '.', '', '../test', 'a/b', 'a\u0000b']) {
        expect(validateFileName(name), isNotNull);
      }
      expect(validateFileName('hello world.txt'), isNull);
    },
  );
}
