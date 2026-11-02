import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../services/remote_session.dart';

class SshTerminal extends StatefulWidget {
  const SshTerminal({
    super.key,
    required this.session,
    this.initialDirectory,
    this.active = true,
  });
  final String? initialDirectory;
  final bool active;
  final RemoteSession session;
  @override
  State<SshTerminal> createState() => _SshTerminalState();
}

class _SshTerminalState extends State<SshTerminal> {
  final terminal = Terminal(maxLines: 10000);
  final controller = TerminalController();
  final focus = FocusNode();
  SSHSession? shell;
  final subscriptions = <StreamSubscription<String>>[];

  @override
  void initState() {
    super.initState();
    start();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active) focus.requestFocus();
    });
  }

  @override
  void didUpdateWidget(covariant SshTerminal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) focus.requestFocus();
    if (!widget.active && oldWidget.active) focus.unfocus();
  }

  Future<void> start() async {
    try {
      final session = await widget.session.client.shell(
        pty: const SSHPtyConfig(),
      );
      if (!mounted) {
        session.close();
        return;
      }
      shell = session;
      for (final stream in [session.stdout, session.stderr]) {
        subscriptions.add(
          stream
              .cast<List<int>>()
              .transform(const Utf8Decoder(allowMalformed: true))
              .listen(
                terminal.write,
                onError: (Object e) => terminal.write('\r\n$e\r\n'),
              ),
        );
      }
      terminal.onOutput = (data) =>
          session.stdin.add(Uint8List.fromList(utf8.encode(data)));
      terminal.onResize = (w, h, pw, ph) =>
          session.resizeTerminal(w, h, pw, ph);
      session.resizeTerminal(terminal.viewWidth, terminal.viewHeight);
      if (widget.initialDirectory != null) {
        session.stdin.add(
          Uint8List.fromList(
            utf8.encode(terminalDirectoryCommand(widget.initialDirectory!)),
          ),
        );
      }
      await session.done;
      if (mounted) {
        terminal.onOutput = null;
        terminal.onResize = null;
        terminal.write(
          '\r\n[Shell closed. Open a new terminal to continue.]\r\n',
        );
      }
    } catch (e) {
      if (mounted) terminal.write('\r\nUnable to open terminal: $e\r\n');
    }
  }

  @override
  void dispose() {
    terminal.onOutput = null;
    terminal.onResize = null;
    for (final subscription in subscriptions) {
      subscription.cancel();
    }
    shell?.close();
    controller.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xff101419),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: TerminalView(
        terminal,
        controller: controller,
        autofocus: widget.active,
        focusNode: focus,
        textStyle: const TerminalStyle(fontSize: 13, fontFamily: 'monospace'),
        onSecondaryTapDown: (_, _) async {
          final selection = controller.selection;
          if (selection != null) {
            await Clipboard.setData(
              ClipboardData(text: terminal.buffer.getText(selection)),
            );
            controller.clearSelection();
          } else {
            final data = await Clipboard.getData('text/plain');
            if (mounted && data?.text != null) terminal.paste(data!.text!);
          }
        },
      ),
    ),
  );
}

String terminalDirectoryCommand(String path) {
  if (!path.startsWith('/') || path.contains('\u0000')) {
    throw ArgumentError('An absolute folder path is required');
  }
  final quoted = "'${path.replaceAll("'", "'\"'\"'")}'";
  return 'cd -- $quoted\r';
}
