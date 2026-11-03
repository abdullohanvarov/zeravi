import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../data/bot_project.dart';
import 'remote_session.dart';

typedef HostingEvent = void Function(String kind, String message);

class BotHostingService {
  BotHostingService(this.remote);
  final RemoteSession remote;
  static Future<String>? _helper;

  Future<Map<String, dynamic>> invoke(
    Map<String, dynamic> request, {
    HostingEvent? event,
  }) async {
    final helper = await (_helper ??= rootBundle.loadString(
      'assets/hosting/manager.py',
    ));
    final encoded = base64.encode(utf8.encode(helper));
    // All user values, including tokens, travel over stdin rather than argv.
    final command =
        'python3 -u -c \'import base64;exec(compile(base64.b64decode("$encoded"),"zeravi-hosting","exec"))\'';
    final execution = remote.client.execute(command);
    late final SSHSession session;
    try {
      session = await execution.timeout(const Duration(seconds: 15));
    } on TimeoutException {
      execution
          .then<void>(
            (lateSession) => lateSession.close(),
            onError: (Object _) {},
          )
          .ignore();
      rethrow;
    }
    Map<String, dynamic>? result;
    String? error;
    final stderr = StringBuffer();
    final values =
        (request['environment'] as Map?)?.values
            .whereType<String>()
            .where((s) => s.length >= 4)
            .toList() ??
        <String>[];
    String scrub(String text) {
      for (final value in values) {
        text = text.replaceAll(value, '[redacted]');
      }
      return text;
    }

    final output = session.stdout
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
          try {
            final value = jsonDecode(line) as Map<String, dynamic>;
            final kind = value['event'] as String? ?? '';
            if (kind == 'result') {
              result = (value['data'] as Map).cast<String, dynamic>();
            } else if (kind == 'error') {
              error = scrub(
                value['message'] as String? ?? 'Hosting operation failed.',
              );
            } else {
              event?.call(kind, scrub(value['message'] as String? ?? ''));
            }
          } catch (_) {
            if (line.trim().isNotEmpty) event?.call('log', scrub(line));
          }
        });
    final errors = session.stderr
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((text) {
          if (stderr.length < 65536) stderr.write(scrub(text));
        });
    try {
      session.stdin.add(Uint8List.fromList(utf8.encode(jsonEncode(request))));
      await session.stdin.close();
      await Future.wait([
        output.asFuture<void>(),
        errors.asFuture<void>(),
        session.done,
      ]).timeout(Duration(seconds: request['action'] == 'deploy' ? 1200 : 60));
      if (error != null) throw BotHostingException(error!);
      if (result == null) {
        throw BotHostingException(
          stderr.isEmpty
              ? 'The server did not respond to the hosting request.'
              : 'Hosting requires Python 3 on the VPS. ${stderr.toString().trim()}',
        );
      }
      return result!;
    } finally {
      await output.cancel();
      await errors.cancel();
      session.close();
    }
  }

  Future<HostedBot> deploy(
    BotProject project,
    Map<String, dynamic> settings, {
    HostingEvent? event,
  }) async {
    final stat = await File(project.path).stat();
    if (stat.size != project.size ||
        stat.modified.millisecondsSinceEpoch != project.modified) {
      throw const BotHostingException(
        'The ZIP changed after inspection. Choose it again before deploying.',
      );
    }
    final home = await remote.sftp.absolute('.');
    final uploadPath =
        '$home/.zeravi-upload-${DateTime.now().microsecondsSinceEpoch}-${settings['id'] ?? 'new'}.zip';
    final file = await remote.sftp.open(
      uploadPath,
      mode:
          SftpFileOpenMode.write |
          SftpFileOpenMode.create |
          SftpFileOpenMode.exclusive,
    );
    try {
      await file.setStat(SftpFileAttrs(mode: SftpFileMode.value(0x180)));
      event?.call(
        'progress',
        'Uploading ${project.size ~/ 1024} KiB project ZIP',
      );
      await file.write(File(project.path).openRead().map(Uint8List.fromList));
      await file.close();
      final response = await invoke({
        'action': 'deploy',
        ...settings,
        'zipPath': uploadPath,
      }, event: event);
      return HostedBot(response);
    } finally {
      await file.close();
      try {
        await remote.sftp.remove(uploadPath);
      } catch (_) {
        /* The helper normally removes it first. */
      }
    }
  }
}

class BotHostingController extends ChangeNotifier {
  BotHostingController(this.service);
  final BotHostingService service;
  bool busy = false, refreshing = false, _disposed = false;
  String stage = '', error = '', refreshError = '', notice = '';
  Map<String, dynamic>? doctor;
  List<HostedBot> bots = [];
  final List<String> activity = [];
  bool get ready => doctor?['ready'] == true;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _event(String kind, String message) {
    if (kind == 'progress') stage = message;
    if (message.isNotEmpty) {
      activity.add(message);
      if (activity.length > 1000) activity.removeAt(0);
    }
    _notify();
  }

  Future<void> refresh() async {
    if (refreshing || busy || _disposed) return;
    refreshing = true;
    _notify();
    try {
      final response = await service.invoke({'action': 'list'});
      if (_disposed) return;
      doctor = (response['doctor'] as Map).cast<String, dynamic>();
      bots = (response['bots'] as List)
          .map((bot) => HostedBot((bot as Map).cast<String, dynamic>()))
          .toList();
      refreshError = '';
    } catch (e) {
      if (!_disposed) refreshError = '$e';
    } finally {
      refreshing = false;
      _notify();
    }
  }

  Future<bool> run(
    String label,
    Future<void> Function(HostingEvent) operation,
  ) async {
    if (busy || _disposed) return false;
    busy = true;
    stage = label;
    error = '';
    notice = '';
    activity.clear();
    _notify();
    var success = false;
    try {
      await operation(_event);
      notice = '$label completed.';
      success = true;
    } catch (e) {
      error = '$e';
      activity.add(error);
    } finally {
      busy = false;
      _notify();
      await refresh();
    }
    return success;
  }

  Future<bool> deploy(BotProject project, Map<String, dynamic> settings) =>
      run('Deploy project', (event) async {
        await service.deploy(project, settings, event: event);
      });
  Future<bool> action(
    String action,
    String botId, [
    Map<String, dynamic> options = const {},
  ]) => run(action == 'control' ? '${options['verb']}' : action, (event) async {
    final result = await service.invoke({
      'action': action,
      'id': botId,
      ...options,
    }, event: event);
    if (result['archive'] != null) {
      activity.add('Project data archived at ${result['archive']}');
    }
  });
  Future<String> logs(String id) async {
    final value = await service.invoke({'action': 'logs', 'id': id});
    if (value['available'] == false) {
      throw const BotHostingException(
        'The server journal could not be read for this user.',
      );
    }
    return value['text'] as String? ?? '';
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
