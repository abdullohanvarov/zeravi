import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../data/connection.dart';

class ConnectionDialog extends StatefulWidget {
  const ConnectionDialog({super.key, this.connection});
  final ServerConnection? connection;
  @override
  State<ConnectionDialog> createState() => _ConnectionDialogState();
}

class _ConnectionDialogState extends State<ConnectionDialog> {
  final form = GlobalKey<FormState>();
  late final name = TextEditingController(text: widget.connection?.name ?? '');
  late final host = TextEditingController(text: widget.connection?.host ?? '');
  late final user = TextEditingController(
    text: widget.connection?.username ?? 'ubuntu',
  );
  late final port = TextEditingController(
    text: '${widget.connection?.port ?? 22}',
  );
  late final keyPath = TextEditingController(
    text: widget.connection?.keyPath ?? '',
  );
  late final alias = TextEditingController(
    text: widget.connection?.vscodeAlias ?? '',
  );
  late AuthMethod method =
      widget.connection?.authMethod ?? AuthMethod.privateKey;

  @override
  void dispose() {
    for (final c in [name, host, user, port, keyPath, alias]) {
      c.dispose();
    }
    super.dispose();
  }

  void save() {
    if (!form.currentState!.validate()) return;
    Navigator.pop(
      context,
      ServerConnection(
        id:
            widget.connection?.id ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        name: name.text.trim(),
        host: host.text.trim(),
        username: user.text.trim(),
        port: int.parse(port.text),
        authMethod: method,
        keyPath: keyPath.text.trim(),
        vscodeAlias: alias.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.connection == null ? 'Add a server' : 'Edit server'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Your workspace starts with a connection.'),
              const SizedBox(height: 24),
              TextFormField(
                controller: name,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Connection name',
                  hintText: 'Production server',
                ),
                validator: (v) => v == null || v.trim().isEmpty
                    ? 'Give this server a name'
                    : null,
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: host,
                      decoration: const InputDecoration(
                        labelText: 'Hostname or IP',
                        hintText: '192.0.2.10',
                      ),
                      validator: validateHost,
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 90,
                    child: TextFormField(
                      controller: port,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Port'),
                      validator: validatePort,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: user,
                decoration: const InputDecoration(labelText: 'Username'),
                validator: (v) => v == null || v.trim().isEmpty
                    ? 'Enter your server username'
                    : null,
              ),
              const SizedBox(height: 20),
              SegmentedButton<AuthMethod>(
                segments: const [
                  ButtonSegment(
                    value: AuthMethod.privateKey,
                    label: Text('SSH key'),
                    icon: Icon(Icons.key_rounded),
                  ),
                  ButtonSegment(
                    value: AuthMethod.password,
                    label: Text('Password'),
                    icon: Icon(Icons.lock_outline),
                  ),
                ],
                selected: {method},
                onSelectionChanged: (values) =>
                    setState(() => method = values.first),
              ),
              const SizedBox(height: 16),
              if (method == AuthMethod.privateKey)
                TextFormField(
                  controller: keyPath,
                  decoration: InputDecoration(
                    labelText: 'Private key file',
                    hintText: '~/.ssh/id_ed25519',
                    suffixIcon: IconButton(
                      tooltip: 'Choose key file',
                      icon: const Icon(Icons.folder_open),
                      onPressed: () async {
                        final file = await openFile();
                        if (file != null && mounted) keyPath.text = file.path;
                      },
                    ),
                  ),
                  validator: (v) => v == null || v.trim().isEmpty
                      ? 'Choose an existing private key'
                      : null,
                ),
              const SizedBox(height: 16),
              TextFormField(
                controller: alias,
                decoration: const InputDecoration(
                  labelText: 'VS Code SSH alias (optional)',
                  hintText: 'my-server',
                  helperText:
                      'An existing Host entry in your local ~/.ssh/config',
                ),
                validator: (v) =>
                    v != null &&
                        v.trim().isNotEmpty &&
                        !RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]*$')
                            .hasMatch(v.trim())
                    ? 'Use letters, numbers, dots, underscores or hyphens'
                    : null,
              ),
              const SizedBox(height: 20),
              const Text(
                'Passwords and key passphrases are requested when connecting and are not saved.',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: save, child: const Text('Save connection')),
    ],
  );
}

Future<String?> requestSecret(
  BuildContext context,
  ServerConnection connection,
) async {
  final controller = TextEditingController();
  final isKey = connection.authMethod == AuthMethod.privateKey;
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(isKey ? 'Unlock SSH key' : 'Connect to ${connection.name}'),
      content: SizedBox(
        width: 380,
        child: TextField(
          controller: controller,
          autofocus: true,
          obscureText: true,
          enableSuggestions: false,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: isKey ? 'Key passphrase' : 'Password',
            helperText: isKey
                ? 'Leave empty if the key has no passphrase.'
                : 'Used only for this connection.',
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: const Text('Connect'),
        ),
      ],
    ),
  );
  // The dialog's route transition can still reference its controller briefly.
  await Future<void>.delayed(const Duration(milliseconds: 300));
  controller.dispose();
  return result;
}
