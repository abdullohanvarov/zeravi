import 'package:flutter_test/flutter_test.dart';
import 'package:zeravi/services/server_monitor.dart';

String sample({int user = 100, int idle = 800, int rx = 1000, int tx = 500}) =>
    '''__Z_HOST__
test-server
Linux test
__Z_CPU__
cpu $user 0 100 $idle 0 0 0 0 10 0
__Z_MEM__
MemTotal: 1000 kB
MemAvailable: 400 kB
SwapTotal: 200 kB
SwapFree: 150 kB
__Z_LOAD__
1.00 2.00 3.00 1/100 500
__Z_UPTIME__
90061.1 0
__Z_NET__
eth0: $rx 0 0 0 0 0 0 0 $tx 0 0 0 0 0 0 0
lo: 9000 0 0 0 0 0 0 0 9000 0 0 0 0 0 0 0
__Z_ROUTE__
Iface Destination Gateway Flags
eth0 00000000 0100000A 0003
__Z_DISK__
Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/vda1 1000 400 550 40% /
/dev/vdb1 2000 500 1400 25% /data mount
__Z_PS__
PID %CPU %MEM COMMAND
12 33.3 4.2 worker
13 1.0 0.1 sshd
__Z_END__
''';

void main() {
  test('Linux parser reports memory, filesystems, processes and load without guest CPU double counting', () {
    final data = ServerSnapshot.parse(sample(), DateTime.utc(2026));
    expect(data.hostname, 'test-server');
    expect(data.cpuTotal, 1000);
    expect(data.cpuPercent, isNull);
    expect(data.memoryUsed, 600 * 1024);
    expect(data.memoryAvailable, 400 * 1024);
    expect(data.load, [1, 2, 3]);
    expect(data.uptime, 90061.1);
    expect(data.disks.first.available, 550 * 1024);
    expect(data.disks.last.mount, '/data mount');
    expect(data.processes.first.pid, 12);
    expect(data.processes.first.cpu, 33.3);
    expect(data.interface, 'eth0');
    expect(data.receiveRate, isNull);
  });
  test('CPU and interface rates use sample deltas and monotonic counters', () {
    final first = ServerSnapshot.parse(sample(), DateTime.utc(2026));
    final next = ServerSnapshot.parse(
      sample(user: 160, idle: 940, rx: 5000, tx: 2500),
      DateTime.utc(2026).add(const Duration(seconds: 2)),
      previous: first,
    );
    expect(next.cpuPercent, closeTo(30, .001));
    expect(next.receiveRate, 2000);
    expect(next.sendRate, 1000);
    final reset = ServerSnapshot.parse(
      sample(user: 0, idle: 0, rx: 0, tx: 0),
      DateTime.utc(2026).add(const Duration(seconds: 4)),
      previous: next,
    );
    expect(reset.cpuPercent, isNull);
    expect(reset.receiveRate, isNull);
  });
  test(
    'invalid output is rejected and missing sections remain unavailable',
    () {
      expect(
        () => ServerSnapshot.parse('command ok', DateTime.now()),
        throwsFormatException,
      );
      final partial = ServerSnapshot.parse(
        '__Z_CPU__\ncpu 1 0 1 2 0 0 0 0\n__Z_END__\n',
        DateTime.now(),
      );
      expect(partial.memoryUsed, isNull);
      expect(partial.disks, isEmpty);
      expect(partial.processes, isEmpty);
    },
  );
}
