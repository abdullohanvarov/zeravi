import 'package:flutter/material.dart';

import '../services/server_monitor.dart';

String humanBytes(num? bytes) {
  if (bytes == null) return 'Unavailable';
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}

String uptimeText(double? seconds) {
  if (seconds == null) return 'Unavailable';
  final d = Duration(seconds: seconds.floor());
  return '${d.inDays}d ${d.inHours % 24}h ${d.inMinutes % 60}m';
}

class ServerDashboard extends StatelessWidget {
  const ServerDashboard({
    super.key,
    required this.monitor,
    required this.onInterval,
  });
  final ServerMonitor monitor;
  final ValueChanged<int> onInterval;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: monitor,
    builder: (context, _) {
      final data = monitor.snapshot;
      final colors = Theme.of(context).colorScheme;
      final root = data?.disks.where((disk) => disk.mount == '/').firstOrNull;
      final swapUsed = data?.swapTotal == null || data?.swapFree == null
          ? null
          : data!.swapTotal! - data.swapFree!;
      return SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              spacing: 24,
              runSpacing: 12,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      data?.hostname ?? 'Server overview',
                      style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      data?.kernel ?? 'Reading server metrics over SSH…',
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButton<int>(
                      value: monitor.seconds,
                      items: [2, 5, 10, 30]
                          .map(
                            (s) => DropdownMenuItem(
                              value: s,
                              child: Text(
                                'Every ${s}s',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value != null) onInterval(value);
                      },
                    ),
                    IconButton(
                      tooltip: monitor.paused
                          ? 'Resume monitoring'
                          : 'Pause monitoring',
                      onPressed: () =>
                          monitor.configure(pause: !monitor.paused),
                      icon: Icon(
                        monitor.paused ? Icons.play_arrow : Icons.pause,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Refresh metrics',
                      onPressed: monitor.busy ? null : monitor.refresh,
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              monitor.paused
                  ? 'Monitoring paused'
                  : data == null
                  ? 'Waiting for first sample'
                  : '${monitor.error != null ? 'Last successful sample' : 'Updated'} ${TimeOfDay.fromDateTime(data.time.toLocal()).format(context)}',
              style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
            ),
            if (monitor.error != null)
              Container(
                margin: const EdgeInsets.only(top: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.errorContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'Metrics could not be refreshed. ${monitor.error}',
                  style: TextStyle(
                    color: colors.onErrorContainer,
                    fontSize: 12,
                  ),
                ),
              ),
            if (monitor.busy && data == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: LinearProgressIndicator(),
              ),
            const SizedBox(height: 24),
            LayoutBuilder(
              builder: (context, c) {
                final columns = c.maxWidth >= 1000
                    ? 4
                    : c.maxWidth >= 560
                    ? 2
                    : 1;
                final width = (c.maxWidth - (columns - 1) * 14) / columns;
                return Wrap(
                  spacing: 14,
                  runSpacing: 14,
                  children: [
                    metric(
                      context,
                      width,
                      'CPU usage',
                      data?.cpuPercent == null
                          ? data == null
                                ? '—'
                                : data.cpuTotal == null
                                ? 'Unavailable'
                                : 'Sampling…'
                          : '${data!.cpuPercent!.toStringAsFixed(1)}%',
                      data?.cpuPercent == null
                          ? data?.cpuTotal == null
                                ? 'CPU counters unavailable'
                                : 'Needs two samples'
                          : 'Across all CPU cores',
                      data?.cpuPercent == null ? null : data!.cpuPercent! / 100,
                      Icons.speed,
                    ),
                    metric(
                      context,
                      width,
                      'Memory',
                      humanBytes(data?.memoryUsed),
                      '${humanBytes(data?.memoryAvailable)} available / ${humanBytes(data?.memoryTotal)} total',
                      data?.memoryTotal == null ||
                              data!.memoryTotal == 0 ||
                              data.memoryUsed == null
                          ? null
                          : data.memoryUsed! / data.memoryTotal!,
                      Icons.memory,
                    ),
                    metric(
                      context,
                      width,
                      'Root disk',
                      root == null
                          ? 'Unavailable'
                          : '${(root.fraction * 100).toStringAsFixed(1)}%',
                      root == null
                          ? 'No root filesystem reported'
                          : '${humanBytes(root.available)} available / ${humanBytes(root.total)} total',
                      root?.fraction,
                      Icons.storage,
                    ),
                    metric(
                      context,
                      width,
                      'Network',
                      data?.receiveRate == null
                          ? data?.interface == null
                                ? 'Unavailable'
                                : 'Sampling…'
                          : '↓ ${humanBytes(data!.receiveRate)}/s',
                      data?.sendRate == null
                          ? 'Interface: ${data?.interface ?? 'unavailable'}'
                          : '↑ ${humanBytes(data!.sendRate)}/s · ${data.interface}',
                      null,
                      Icons.swap_vert,
                    ),
                    metric(
                      context,
                      width,
                      'Uptime',
                      uptimeText(data?.uptime),
                      'Time since last boot',
                      null,
                      Icons.schedule,
                    ),
                    metric(
                      context,
                      width,
                      'Load average',
                      data?.load.isEmpty ?? true
                          ? 'Unavailable'
                          : data!.load
                                .map((v) => v.toStringAsFixed(2))
                                .join(' / '),
                      '1 / 5 / 15 minute averages',
                      null,
                      Icons.show_chart,
                    ),
                    metric(
                      context,
                      width,
                      'Swap',
                      data?.swapTotal == 0
                          ? 'Not configured'
                          : humanBytes(swapUsed),
                      data?.swapTotal == 0
                          ? 'No swap reported'
                          : '${humanBytes(data?.swapTotal)} total',
                      data?.swapTotal == null ||
                              data!.swapTotal == 0 ||
                              swapUsed == null
                          ? null
                          : swapUsed / data.swapTotal!,
                      Icons.disc_full_outlined,
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 24),
            const Text(
              'CPU history',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 70,
              child: CustomPaint(
                painter: _CpuHistory(
                  monitor.cpuHistory,
                  colors.primary,
                  colors.outlineVariant,
                ),
                child: const SizedBox.expand(),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Filesystems',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            if (data?.disks.isEmpty ?? true)
              const Text(
                'No filesystem data available.',
                style: TextStyle(fontSize: 12),
              )
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('Mount')),
                    DataColumn(label: Text('Filesystem')),
                    DataColumn(label: Text('Used')),
                    DataColumn(label: Text('Available')),
                    DataColumn(label: Text('Total')),
                  ],
                  rows: data!.disks
                      .map(
                        (disk) => DataRow(
                          cells: [
                            DataCell(SelectableText(disk.mount)),
                            DataCell(Text(disk.filesystem)),
                            DataCell(
                              Text(
                                '${(disk.fraction * 100).toStringAsFixed(1)}%',
                              ),
                            ),
                            DataCell(Text(humanBytes(disk.available))),
                            DataCell(Text(humanBytes(disk.total))),
                          ],
                        ),
                      )
                      .toList(),
                ),
              ),
            const SizedBox(height: 24),
            const Text(
              'Top processes',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              'CPU is the process lifetime average reported by ps. System processes may be restricted by the server.',
              style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
            ),
            if (data?.processes.isEmpty ?? true)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(
                  'No process data available.',
                  style: TextStyle(fontSize: 12),
                ),
              )
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('PID')),
                    DataColumn(label: Text('Command')),
                    DataColumn(label: Text('CPU %'), numeric: true),
                    DataColumn(label: Text('RAM %'), numeric: true),
                  ],
                  rows: data!.processes
                      .map(
                        (process) => DataRow(
                          cells: [
                            DataCell(Text('${process.pid}')),
                            DataCell(SelectableText(process.command)),
                            DataCell(Text(process.cpu.toStringAsFixed(1))),
                            DataCell(Text(process.memory.toStringAsFixed(1))),
                          ],
                        ),
                      )
                      .toList(),
                ),
              ),
          ],
        ),
      );
    },
  );

  Widget metric(
    BuildContext context,
    double width,
    String title,
    String value,
    String detail,
    double? fraction,
    IconData icon,
  ) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: width,
      constraints: const BoxConstraints(minHeight: 150),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: colors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(title, style: const TextStyle(fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            value,
            style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            detail,
            style: TextStyle(fontSize: 10, color: colors.onSurfaceVariant),
          ),
          if (fraction != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(
                value: fraction.clamp(0, 1),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
        ],
      ),
    );
  }
}

class _CpuHistory extends CustomPainter {
  _CpuHistory(List<double?> values, this.color, this.grid)
    : values = List.of(values);
  final List<double?> values;
  final Color color, grid;
  @override
  void paint(Canvas canvas, Size size) {
    final background = Paint()
      ..color = grid
      ..strokeWidth = .5;
    for (final fraction in [0.0, .5, 1.0]) {
      canvas.drawLine(
        Offset(0, size.height * fraction),
        Offset(size.width, size.height * fraction),
        background,
      );
    }
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final path = Path();
    var begun = false;
    for (var i = 0; i < values.length; i++) {
      final value = values[i];
      if (value == null) {
        begun = false;
        continue;
      }
      final x = i / 39 * size.width, y = size.height * (1 - value / 100);
      if (!begun) {
        path.moveTo(x, y);
        begun = true;
      } else {
        path.lineTo(x, y);
      }
      canvas.drawCircle(Offset(x, y), 2, Paint()..color = color);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _CpuHistory old) => true;
}
