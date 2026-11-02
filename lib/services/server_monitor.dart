import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:dartssh2/dartssh2.dart';

/// Static, read-only Linux queries. No paths or user input are interpolated.
const monitoringCommand = r'''LC_ALL=C; export LC_ALL
printf '__Z_HOST__\n'; uname -n; uname -sr
printf '__Z_CPU__\n'; head -n 1 /proc/stat
printf '__Z_MEM__\n'; cat /proc/meminfo
printf '__Z_LOAD__\n'; cat /proc/loadavg
printf '__Z_UPTIME__\n'; cat /proc/uptime
printf '__Z_NET__\n'; cat /proc/net/dev
printf '__Z_ROUTE__\n'; cat /proc/net/route
printf '__Z_DISK__\n'; df -Pk -x tmpfs -x devtmpfs
printf '__Z_PS__\n'; ps -eo pid,pcpu,pmem,comm --sort=-pcpu | head -n 16
printf '__Z_END__\n'
''';

class DiskUsage {
  const DiskUsage(
    this.filesystem,
    this.total,
    this.used,
    this.available,
    this.mount,
  );
  final String filesystem;
  final int total, used, available;
  final String mount;
  double get fraction => total == 0 ? 0 : (used / total).clamp(0, 1);
}

class ProcessUsage {
  const ProcessUsage(this.pid, this.cpu, this.memory, this.command);
  final int pid;
  final double cpu, memory;
  final String command;
}

class NetworkCounter {
  const NetworkCounter(this.received, this.sent);
  final int received, sent;
}

class ServerSnapshot {
  ServerSnapshot({
    required this.time,
    required this.hostname,
    required this.kernel,
    required this.cpuTotal,
    required this.cpuIdle,
    required this.memoryTotal,
    required this.memoryAvailable,
    required this.swapTotal,
    required this.swapFree,
    required this.load,
    required this.uptime,
    required this.network,
    required this.defaultInterface,
    required this.disks,
    required this.processes,
  });
  final DateTime time;
  final String hostname, kernel;
  final int? cpuTotal,
      cpuIdle,
      memoryTotal,
      memoryAvailable,
      swapTotal,
      swapFree;
  final List<double> load;
  final double? uptime;
  final Map<String, NetworkCounter> network;
  final String? defaultInterface;
  final List<DiskUsage> disks;
  final List<ProcessUsage> processes;
  double? cpuPercent, receiveRate, sendRate;
  String? interface;
  int? get memoryUsed => memoryTotal == null || memoryAvailable == null
      ? null
      : (memoryTotal! - memoryAvailable!).clamp(0, memoryTotal!);

  factory ServerSnapshot.parse(
    String output,
    DateTime time, {
    ServerSnapshot? previous,
  }) {
    final blocks = <String, List<String>>{};
    String? section;
    for (final line in const LineSplitter().convert(output)) {
      if (line.startsWith('__Z_') && line.endsWith('__')) {
        section = line;
        blocks[section] = [];
      } else if (section != null) {
        blocks[section]!.add(line);
      }
    }
    if (!blocks.containsKey('__Z_END__') || !blocks.containsKey('__Z_CPU__')) {
      throw const FormatException(
        'This server did not return Linux monitoring data.',
      );
    }
    List<String> lines(String key) => blocks['__Z_${key}__'] ?? [];
    final cpu =
        lines('CPU')
            .where((l) => l.startsWith('cpu '))
            .firstOrNull
            ?.trim()
            .split(RegExp(r'\s+'))
            .skip(1)
            .map(int.tryParse)
            .toList() ??
        [];
    final memory = <String, int>{};
    for (final line in lines('MEM')) {
      final match = RegExp(r'^(\w+):\s+(\d+)').firstMatch(line);
      if (match != null) memory[match[1]!] = int.parse(match[2]!) * 1024;
    }
    final network = <String, NetworkCounter>{};
    for (final line in lines('NET')) {
      final parts = line.split(':');
      if (parts.length != 2) continue;
      final values = parts[1].trim().split(RegExp(r'\s+'));
      if (values.length >= 9) {
        final received = int.tryParse(values[0]);
        final sent = int.tryParse(values[8]);
        if (received != null && sent != null) {
          network[parts[0].trim()] = NetworkCounter(received, sent);
        }
      }
    }
    String? defaultInterface;
    for (final line in lines('ROUTE').skip(1)) {
      final fields = line.trim().split(RegExp(r'\s+'));
      if (fields.length >= 4 &&
          fields[1] == '00000000' &&
          ((int.tryParse(fields[3], radix: 16) ?? 0) & 2) != 0) {
        defaultInterface = fields[0];
        break;
      }
    }
    final disks = <DiskUsage>[];
    for (final line in lines('DISK').skip(1)) {
      final fields = line.trim().split(RegExp(r'\s+'));
      if (fields.length < 6) continue;
      final total = int.tryParse(fields[1]),
          used = int.tryParse(fields[2]),
          available = int.tryParse(fields[3]);
      if (total != null && used != null && available != null) {
        disks.add(
          DiskUsage(
            fields[0],
            total * 1024,
            used * 1024,
            available * 1024,
            fields.skip(5).join(' '),
          ),
        );
      }
    }
    final processes = <ProcessUsage>[];
    for (final line in lines('PS').skip(1)) {
      final fields = line.trim().split(RegExp(r'\s+'));
      if (fields.length < 4) continue;
      final pid = int.tryParse(fields[0]),
          cpu = double.tryParse(fields[1]),
          mem = double.tryParse(fields[2]);
      if (pid != null && cpu != null && mem != null) {
        processes.add(ProcessUsage(pid, cpu, mem, fields.skip(3).join(' ')));
      }
    }
    final host = lines('HOST');
    final snap = ServerSnapshot(
      time: time,
      hostname: host.firstOrNull ?? 'Unknown host',
      kernel: host.length > 1 ? host[1] : '',
      cpuTotal: cpu.length >= 8 && cpu.take(8).every((v) => v != null)
          ? cpu.take(8).fold<int>(0, (sum, v) => sum + v!)
          : null,
      cpuIdle: cpu.length >= 5 && cpu[3] != null && cpu[4] != null
          ? cpu[3]! + cpu[4]!
          : null,
      memoryTotal: memory['MemTotal'],
      memoryAvailable: memory['MemAvailable'],
      swapTotal: memory['SwapTotal'],
      swapFree: memory['SwapFree'],
      load: (lines('LOAD').firstOrNull ?? '')
          .split(RegExp(r'\s+'))
          .take(3)
          .map(double.tryParse)
          .whereType<double>()
          .toList(),
      uptime: double.tryParse(
        (lines('UPTIME').firstOrNull ?? '').split(' ').first,
      ),
      network: network,
      defaultInterface: defaultInterface,
      disks: disks,
      processes: processes,
    );
    if (previous != null &&
        snap.cpuTotal != null &&
        previous.cpuTotal != null &&
        snap.cpuIdle != null &&
        previous.cpuIdle != null) {
      final total = snap.cpuTotal! - previous.cpuTotal!,
          idle = snap.cpuIdle! - previous.cpuIdle!;
      if (total > 0 && idle >= 0) {
        snap.cpuPercent = ((total - idle) / total * 100).clamp(0, 100);
      }
    }
    snap.interface =
        defaultInterface ??
        network.keys.where((name) => name != 'lo').firstOrNull;
    final before = previous?.network[snap.interface],
        now = network[snap.interface];
    final seconds = previous == null
        ? 0.0
        : time.difference(previous.time).inMicroseconds / 1000000;
    if (before != null &&
        now != null &&
        seconds > 0 &&
        now.received >= before.received &&
        now.sent >= before.sent) {
      snap.receiveRate = (now.received - before.received) / seconds;
      snap.sendRate = (now.sent - before.sent) / seconds;
    }
    return snap;
  }
}

Future<ServerSnapshot> readServerSnapshot(
  SSHClient client, {
  ServerSnapshot? previous,
}) async {
  final execution = client.execute(monitoringCommand);
  late final SSHSession shell;
  try {
    shell = await execution.timeout(const Duration(seconds: 12));
  } on TimeoutException {
    // If the server acknowledges the channel after the timeout, release it.
    execution
        .then<void>(
          (lateSession) => lateSession.close(),
          onError: (Object _) {},
        )
        .ignore();
    rethrow;
  }
  final output = StringBuffer();
  final subscription = shell.stdout
      .cast<List<int>>()
      .transform(const Utf8Decoder(allowMalformed: true))
      .listen((chunk) {
        if (output.length < 512 * 1024) output.write(chunk);
      });
  final errors = shell.stderr.drain<void>();
  try {
    await Future.wait([subscription.asFuture<void>(), errors, shell.done])
        .timeout(const Duration(seconds: 12));
    return ServerSnapshot.parse(
      output.toString(),
      DateTime.now(),
      previous: previous,
    );
  } finally {
    await subscription.cancel();
    shell.close();
  }
}

class ServerMonitor extends ChangeNotifier {
  ServerMonitor(this.client, {this.seconds = 5}) {
    _schedule();
    refresh();
  }
  final SSHClient client;
  int seconds;
  bool paused = false, busy = false, _disposed = false;
  String? error;
  ServerSnapshot? snapshot;
  final List<double?> cpuHistory = [];
  Timer? _timer;

  void _schedule() {
    _timer?.cancel();
    if (!paused) {
      _timer = Timer.periodic(Duration(seconds: seconds), (_) => refresh());
    }
  }

  void configure({int? interval, bool? pause}) {
    if (interval != null) seconds = interval;
    if (pause != null) paused = pause;
    _schedule();
    notifyListeners();
    if (!paused) refresh();
  }

  Future<void> refresh() async {
    if (busy || _disposed) return;
    busy = true;
    notifyListeners();
    try {
      final result = await readServerSnapshot(client, previous: snapshot);
      if (_disposed) return;
      snapshot = result;
      error = null;
      cpuHistory.add(result.cpuPercent);
      if (cpuHistory.length > 40) cpuHistory.removeAt(0);
    } catch (e) {
      if (!_disposed) error = '$e';
    } finally {
      busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
