import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../data/bot_project.dart';
import '../services/bot_hosting.dart';

class BotHostingPanel extends StatefulWidget {
  const BotHostingPanel({
    super.key,
    required this.controller,
    required this.onOpenTerminal,
    this.onOpenFiles,
  });
  final BotHostingController controller;
  final ValueChanged<String?> onOpenTerminal;
  final ValueChanged<String>? onOpenFiles;
  @override
  State<BotHostingPanel> createState() => _BotHostingPanelState();
}

class _BotHostingPanelState extends State<BotHostingPanel> {
  Timer? timer;
  BotHostingController get host => widget.controller;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(host.refresh());
    });
    timer = Timer.periodic(const Duration(seconds: 8), (_) => host.refresh());
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  void message(Object text) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$text')));
    }
  }

  Future<void> deploy([HostedBot? bot]) async {
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(label: 'Python project ZIP', extensions: ['zip']),
        ],
      );
      if (file == null || !mounted) return;
      final project = await BotProject.inspect(file.path);
      if (!mounted) return;
      final settings = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (_) => BotSettingsDialog(project: project, bot: bot),
      );
      if (settings != null && mounted) await host.deploy(project, settings);
    } catch (e) {
      message(e);
    }
  }

  Future<void> configure(HostedBot bot) async {
    final settings = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => BotSettingsDialog(bot: bot),
    );
    if (settings != null && mounted) {
      await host.action('configure', bot.id, settings);
    }
  }

  Future<void> rollback(HostedBot bot) async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Roll back ${bot.name}?'),
        content: const Text(
          'Restore the previous code and Python environment, then restart the bot. Current environment variables and persistent data are kept. Database changes made by the newer code are not undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Roll back'),
          ),
        ],
      ),
    );
    if (answer == true) await host.action('rollback', bot.id);
  }

  Future<void> remove(HostedBot bot) async {
    var delete = false;
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text('Remove ${bot.name}?'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Stop and remove the service. By default, project files, configuration and persistent data are archived on this VPS.',
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: delete,
                  onChanged: (v) => update(() => delete = v!),
                  title: const Text('Permanently delete project and data'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(delete ? 'Delete permanently' : 'Archive and remove'),
            ),
          ],
        ),
      ),
    );
    if (answer == true) {
      await host.action('remove', bot.id, {'deleteData': delete});
    }
  }

  void setup() {
    final user = host.doctor?['username'] ?? 'YOUR_USER';
    final quoted = "'${user.toString().replaceAll("'", "'\\''")}'";
    final commands =
        'sudo apt-get install python3 python3-venv\nsudo loginctl enable-linger $quoted';
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Prepare this VPS'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Zeravi uses Python virtual environments and services belonging to your SSH user. Enable linger so the bot continues running after you disconnect and starts after a reboot. A dedicated non-root account is recommended.',
                ),
                const SizedBox(height: 16),
                const Text('Ubuntu / Debian setup (run once in the terminal):'),
                const SizedBox(height: 8),
                SelectableText(
                  commands,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Reconnect after setup, then refresh. Other Linux distributions need equivalent Python and systemd packages. A working systemd user session is required; containers without systemd are unsupported.',
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: commands));
            },
            child: const Text('Copy commands'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              widget.onOpenTerminal(null);
            },
            child: const Text('Open terminal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: host,
    builder: (context, _) => ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              'Bot hosting',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            FilledButton.icon(
              onPressed: host.busy || !host.ready ? null : deploy,
              icon: const Icon(Icons.add),
              label: const Text('Deploy ZIP'),
            ),
            IconButton(
              onPressed: host.busy || host.refreshing ? null : host.refresh,
              tooltip: 'Refresh bot status',
              icon: const Icon(Icons.refresh),
            ),
            TextButton.icon(
              onPressed: setup,
              icon: const Icon(Icons.help_outline),
              label: const Text('Server setup'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'Projects live in ~/telegrambots. Processes keep running when Zeravi closes. Use long polling, or configure your own HTTPS endpoint for webhooks.',
        ),
        const SizedBox(height: 16),
        if (host.refreshing) const LinearProgressIndicator(),
        if (host.doctor != null)
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _check(
                'Python ${host.doctor!['python']}',
                host.doctor!['pythonSupported'] != false,
              ),
              _check('Virtual environments', host.doctor!['venv'] == true),
              _check('User services', host.doctor!['userManager'] == true),
              _check('Run after logout', host.doctor!['linger'] == true),
            ],
          ),
        if (host.doctor != null && !host.ready)
          _notice('Finish server setup to deploy a bot.', error: true),
        if (host.refreshError.isNotEmpty)
          _notice(host.refreshError, error: true),
        if (host.error.isNotEmpty) _notice(host.error, error: true),
        if (host.notice.isNotEmpty) _notice(host.notice),
        if (host.busy || host.activity.isNotEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (host.busy) ...[
                    const LinearProgressIndicator(),
                    const SizedBox(height: 10),
                    Text(host.stage),
                  ],
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('Deployment activity'),
                    initiallyExpanded: host.busy,
                    children: [
                      SizedBox(
                        height: 200,
                        child: SingleChildScrollView(
                          reverse: true,
                          child: SelectableText(
                            host.activity.join('\n'),
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        if (host.bots.isEmpty && !host.refreshing && host.refreshError.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 38),
            child: Column(
              children: [
                Icon(Icons.smart_toy_outlined, size: 46),
                SizedBox(height: 12),
                Text('Your bots will appear here'),
                SizedBox(height: 8),
                Text(
                  'ZIP your project with requirements.txt and main.py.\nYou can choose another Python entry point before deploying.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        for (final bot in host.bots) _bot(bot),
        const SizedBox(height: 12),
        const Text(
          'Status describes the server process. Check logs to confirm the bot connected to Telegram. Only deploy projects and dependencies you trust.',
          style: TextStyle(fontSize: 12),
        ),
      ],
    ),
  );
  Widget _check(String label, bool ok) => Chip(
    avatar: Icon(
      ok ? Icons.check_circle_outline : Icons.warning_amber,
      size: 18,
    ),
    label: Text(label),
  );
  Widget _notice(String text, {bool error = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: SelectableText(
      text,
      style: TextStyle(
        color: error ? Theme.of(context).colorScheme.error : null,
      ),
    ),
  );
  Widget _bot(HostedBot bot) {
    final memory = int.tryParse('${bot.data['memory']}');
    return Card(
      margin: const EdgeInsets.only(top: 14),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(bot.name, style: Theme.of(context).textTheme.titleLarge),
                Chip(label: Text(bot.statusLabel)),
                Text(bot.entrypoint),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'PID ${bot.data['pid'] ?? '—'}  •  RAM ${memory == null ? '—' : '${(memory / 1048576).toStringAsFixed(1)} MiB'}  •  Restarts ${bot.data['restarts'] ?? '0'}  •  Boot: ${bot.autostart ? 'on' : 'off'}',
            ),
            if ('${bot.data['warning'] ?? ''}'.isNotEmpty)
              _notice('${bot.data['warning']}', error: true),
            if (bot.state == 'failed')
              _notice(
                'Exit status: ${bot.data['exitStatus']}; ${bot.data['result']}. Open logs to diagnose the failure.',
                error: true,
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: host.busy
                      ? null
                      : () => host.action('control', bot.id, {
                          'verb': bot.running ? 'stop' : 'start',
                        }),
                  icon: Icon(bot.running ? Icons.stop : Icons.play_arrow),
                  label: Text(bot.running ? 'Stop' : 'Start'),
                ),
                OutlinedButton.icon(
                  onPressed: host.busy
                      ? null
                      : () =>
                            host.action('control', bot.id, {'verb': 'restart'}),
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('Restart'),
                ),
                OutlinedButton.icon(
                  onPressed: host.busy
                      ? null
                      : () => showDialog<void>(
                          context: context,
                          builder: (_) =>
                              BotLogsDialog(controller: host, bot: bot),
                        ),
                  icon: const Icon(Icons.receipt_long),
                  label: const Text('Logs'),
                ),
                OutlinedButton.icon(
                  onPressed: host.busy || !host.ready
                      ? null
                      : () => deploy(bot),
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Update ZIP'),
                ),
                PopupMenuButton<String>(
                  enabled: !host.busy,
                  tooltip: 'Manage ${bot.name}',
                  onSelected: (value) {
                    switch (value) {
                      case 'settings':
                        configure(bot);
                      case 'files':
                        widget.onOpenFiles?.call(bot.path);
                      case 'terminal':
                        widget.onOpenTerminal(bot.path);
                      case 'copy':
                        Clipboard.setData(ClipboardData(text: bot.path));
                        message('Project path copied.');
                      case 'rollback':
                        rollback(bot);
                      case 'remove':
                        remove(bot);
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'settings',
                      child: Text('Settings & environment'),
                    ),
                    if (widget.onOpenFiles != null)
                      const PopupMenuItem(
                        value: 'files',
                        child: Text('Open project in Files'),
                      ),
                    const PopupMenuItem(
                      value: 'terminal',
                      child: Text('Open project in terminal'),
                    ),
                    const PopupMenuItem(
                      value: 'copy',
                      child: Text('Copy project path'),
                    ),
                    PopupMenuItem(
                      value: 'rollback',
                      enabled: bot.previous != null,
                      child: const Text('Roll back previous release'),
                    ),
                    const PopupMenuItem(
                      value: 'remove',
                      child: Text('Remove bot…'),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Updated ${bot.data['updated'] ?? '—'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class BotSettingsDialog extends StatefulWidget {
  const BotSettingsDialog({super.key, this.project, this.bot});
  final BotProject? project;
  final HostedBot? bot;
  @override
  State<BotSettingsDialog> createState() => _BotSettingsDialogState();
}

class _BotSettingsDialogState extends State<BotSettingsDialog> {
  final form = GlobalKey<FormState>();
  late final name = TextEditingController(
    text: widget.bot?.name ?? p.basenameWithoutExtension(widget.project!.path),
  );
  late String root = widget.project?.roots.first ?? '';
  late final entry = TextEditingController(
    text: widget.project != null
        ? (widget.bot != null &&
                  widget.project!.containsEntry(root, widget.bot!.entrypoint)
              ? widget.bot!.entrypoint
              : widget.project!.suggestedEntry(root))
        : widget.bot!.entrypoint,
  );
  final environment = TextEditingController(),
      arguments = TextEditingController(),
      removeEnv = TextEditingController();
  late final persistent = TextEditingController(
    text: (widget.bot?.persistent ?? ['data', 'uploads', 'storage']).join(', '),
  );
  late String restart = widget.bot?.restart ?? 'on-failure';
  late bool autostart = widget.bot?.autostart ?? true;
  bool start = true, reveal = false, replaceArguments = false;
  String? error;
  @override
  void dispose() {
    for (final c in [
      name,
      entry,
      environment,
      arguments,
      removeEnv,
      persistent,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void submit() {
    if (!form.currentState!.validate()) return;
    try {
      final env = parseBotEnvironment(environment.text);
      validateBotRelativePath(entry.text.trim());
      if (!entry.text.trim().endsWith('.py')) {
        throw const BotHostingException('Choose a .py entry point.');
      }
      if (widget.project != null &&
          !widget.project!.containsEntry(root, entry.text.trim())) {
        throw const BotHostingException(
          'That entry point is not in the selected project folder.',
        );
      }
      final paths = persistent.text
          .split(',')
          .map((p) => p.trim())
          .where((p) => p.isNotEmpty)
          .toList();
      for (final path in paths) {
        validateBotRelativePath(path);
        if (path.contains('/') ||
            path.endsWith('.py') ||
            path == 'requirements.txt') {
          throw const BotHostingException(
            'Persistent paths must be top-level data files or folders, for example data or bot.sqlite.',
          );
        }
      }
      Navigator.pop(context, <String, dynamic>{
        if (widget.bot != null) 'id': widget.bot!.id,
        'name': name.text.trim(),
        'entrypoint': entry.text.trim(),
        if (widget.project != null) 'projectRoot': root,
        'environment': env,
        'removeEnv': removeEnv.text
            .split(',')
            .map((p) => p.trim())
            .where((p) => p.isNotEmpty)
            .toList(),
        if (widget.bot == null || replaceArguments)
          'arguments': arguments.text
              .split('\n')
              .where((a) => a.isNotEmpty)
              .toList(),
        'persistent': paths,
        'restart': restart,
        'autostart': autostart,
        'start': start,
      });
    } catch (e) {
      setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.project == null
          ? 'Bot settings'
          : widget.bot == null
          ? 'Deploy Python bot'
          : 'Update ${widget.bot!.name}',
    ),
    content: SizedBox(
      width: 620,
      child: SingleChildScrollView(
        child: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.project != null) ...[
                Text(
                  '${p.basename(widget.project!.path)} • ${(widget.project!.size / 1048576).toStringAsFixed(1)} MiB • ${widget.project!.files.length} files',
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
                  initialValue: root,
                  decoration: const InputDecoration(
                    labelText: 'Project folder (contains requirements.txt)',
                  ),
                  items: widget.project!.roots
                      .map(
                        (r) => DropdownMenuItem(
                          value: r,
                          child: Text(r.isEmpty ? 'ZIP root' : r),
                        ),
                      )
                      .toList(),
                  onChanged: (r) => setState(() {
                    root = r!;
                    entry.text = widget.project!.suggestedEntry(root);
                  }),
                ),
                const SizedBox(height: 14),
              ],
              TextFormField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Bot name'),
                maxLength: 80,
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Enter a name.' : null,
              ),
              TextFormField(
                controller: entry,
                decoration: const InputDecoration(
                  labelText: 'Python entry point',
                  helperText:
                      'Relative to the project folder, for example main.py',
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'Environment variables',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const Text(
                'Use os.environ in Python, for example os.environ["BOT_TOKEN"]. Values are stored privately on the VPS; leave blank to keep existing values.',
              ),
              if (widget.bot?.envKeys.isNotEmpty == true)
                Text('Stored keys: ${widget.bot!.envKeys.join(', ')}'),
              TextField(
                controller: environment,
                obscureText: !reveal,
                maxLines: reveal ? 5 : 1,
                enableSuggestions: false,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: 'NAME=value (one per line)',
                  hintText: 'BOT_TOKEN=your-token',
                  suffixIcon: IconButton(
                    tooltip: reveal ? 'Hide values' : 'Show multiline editor',
                    onPressed: () => setState(() => reveal = !reveal),
                    icon: Icon(
                      reveal ? Icons.visibility_off : Icons.visibility,
                    ),
                  ),
                ),
              ),
              if (widget.bot != null)
                TextField(
                  controller: removeEnv,
                  decoration: const InputDecoration(
                    labelText: 'Remove environment keys',
                    helperText:
                        'Comma-separated names; leave blank to keep all keys',
                  ),
                ),
              const SizedBox(height: 14),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Runtime & persistent data'),
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: restart,
                    decoration: const InputDecoration(
                      labelText: 'Restart policy',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'on-failure',
                        child: Text('Restart after a crash'),
                      ),
                      DropdownMenuItem(
                        value: 'always',
                        child: Text('Always restart after exit'),
                      ),
                      DropdownMenuItem(
                        value: 'no',
                        child: Text('Never restart automatically'),
                      ),
                    ],
                    onChanged: (v) => setState(() => restart = v!),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: autostart,
                    onChanged: (v) => setState(() => autostart = v),
                    title: const Text('Start automatically after reboot'),
                  ),
                  TextField(
                    controller: persistent,
                    decoration: const InputDecoration(
                      labelText: 'Persistent files / folders',
                      helperText: 'Top-level names, separated by commas. Defaults: data, uploads, storage.',
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'Store databases and uploads in these paths to keep them across ZIP updates. ZERAVI_DATA_DIR also points to the shared data directory. Changes to other project files are replaced on update. Removing a path here stops linking it; the shared copy is retained.',
                    ),
                  ),
                  if (widget.bot != null)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: replaceArguments,
                      onChanged: (v) => setState(() => replaceArguments = v!),
                      title: const Text('Replace existing command arguments'),
                    ),
                  if (widget.bot == null || replaceArguments)
                    TextField(
                      controller: arguments,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: 'Command arguments (one per line)',
                        helperText: 'Pass tokens through environment variables instead.',
                      ),
                    ),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: start,
                onChanged: (v) => setState(() => start = v),
                title: Text(
                  widget.project == null
                      ? 'Restart after saving'
                      : 'Start after deployment',
                ),
              ),
              if (widget.bot != null)
                const Text(
                  'Updating or saving settings briefly stops this bot. Avoid running the same Telegram token in another bot process.',
                ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
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
      FilledButton(
        onPressed: submit,
        child: Text(widget.project == null ? 'Save settings' : 'Deploy'),
      ),
    ],
  );
}

class BotLogsDialog extends StatefulWidget {
  const BotLogsDialog({super.key, required this.controller, required this.bot});
  final BotHostingController controller;
  final HostedBot bot;
  @override
  State<BotLogsDialog> createState() => _BotLogsDialogState();
}

class _BotLogsDialogState extends State<BotLogsDialog> {
  Timer? timer;
  bool loading = false, auto = true;
  String text = '', error = '', query = '';
  @override
  void initState() {
    super.initState();
    refresh();
    timer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (auto && !widget.controller.busy) refresh();
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> refresh() async {
    if (loading || widget.controller.busy) return;
    setState(() => loading = true);
    try {
      final logs = await widget.controller.logs(widget.bot.id);
      if (mounted) {
        setState(() {
          text = logs;
          error = '';
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = text
        .split('\n')
        .where((line) => line.toLowerCase().contains(query.toLowerCase()))
        .join('\n');
    return AlertDialog(
      title: Text('${widget.bot.name} — logs'),
      content: SizedBox(
        width: 850,
        height: 480,
        child: Column(
          children: [
            TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Filter latest 200 journal lines',
              ),
              onChanged: (v) => setState(() => query = v),
            ),
            Row(
              children: [
                Checkbox(
                  value: auto,
                  onChanged: (v) => setState(() => auto = v!),
                ),
                const Text('Refresh automatically'),
                const Spacer(),
                IconButton(
                  onPressed: loading ? null : refresh,
                  tooltip: 'Refresh logs',
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            if (loading) const LinearProgressIndicator(),
            if (error.isNotEmpty)
              Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            Expanded(
              child: SingleChildScrollView(
                reverse: true,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SelectableText(
                    filtered.isEmpty ? 'No matching log entries.' : filtered,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ),
            const Text(
              'Stored environment values are masked when possible. Avoid logging credentials in your bot.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Clipboard.setData(ClipboardData(text: filtered)),
          child: const Text('Copy logs'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
