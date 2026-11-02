enum AuthMethod { privateKey, password }

class ServerConnection {
  const ServerConnection({
    required this.id,
    required this.name,
    required this.host,
    required this.username,
    this.port = 22,
    this.authMethod = AuthMethod.privateKey,
    this.keyPath = '',
    this.vscodeAlias = '',
  });

  final String id;
  final String name;
  final String host;
  final String username;
  final int port;
  final AuthMethod authMethod;
  final String keyPath;
  final String vscodeAlias;

  String get address => '$username@$host:$port';

  Map<String, Object?> toMap() => {
    'id': id,
    'name': name,
    'host': host,
    'username': username,
    'port': port,
    'auth_method': authMethod.name,
    'key_path': keyPath,
    'vscode_alias': vscodeAlias,
  };

  factory ServerConnection.fromMap(Map<String, Object?> map) =>
      ServerConnection(
        id: map['id'] as String,
        name: map['name'] as String,
        host: map['host'] as String,
        username: map['username'] as String,
        port: map['port'] as int,
        authMethod: AuthMethod.values.byName(map['auth_method'] as String),
        keyPath: map['key_path'] as String,
        vscodeAlias: map['vscode_alias'] as String,
      );
}

String? validateHost(String? value) {
  final host = value?.trim() ?? '';
  if (host.isEmpty) return 'Enter a hostname or IP address';
  if (host.startsWith('-') || RegExp(r'[\s/\\\x00]').hasMatch(host)) {
    return 'Use a hostname or IP address, without a URL or username';
  }
  return null;
}

String? validatePort(String? value) {
  final port = int.tryParse(value ?? '');
  return port == null || port < 1 || port > 65535
      ? 'Use a port from 1 to 65535'
      : null;
}

String? validateFileName(String? value) {
  if (value == null ||
      value.trim().isEmpty ||
      value == '.' ||
      value == '..' ||
      value.contains('/') ||
      value.contains('\u0000')) {
    return 'Enter a name without /';
  }
  return null;
}
