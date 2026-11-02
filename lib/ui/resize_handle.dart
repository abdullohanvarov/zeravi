import 'package:flutter/material.dart';

/// A discoverable splitter with pointer and double-click reset support.
class HorizontalResizeHandle extends StatefulWidget {
  const HorizontalResizeHandle({
    super.key,
    required this.label,
    required this.onDelta,
    required this.onEnd,
    required this.onReset,
  });
  final String label;
  final ValueChanged<double> onDelta;
  final VoidCallback onEnd, onReset;
  @override
  State<HorizontalResizeHandle> createState() => _HorizontalResizeHandleState();
}

class _HorizontalResizeHandleState extends State<HorizontalResizeHandle> {
  bool hover = false;
  @override
  Widget build(BuildContext context) => Tooltip(
    message: '${widget.label} · double-click to reset',
    child: MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) => widget.onDelta(details.delta.dx),
        onHorizontalDragEnd: (_) => widget.onEnd(),
        onDoubleTap: widget.onReset,
        child: Container(
          width: 8,
          color: hover
              ? Theme.of(context).colorScheme.primary.withValues(alpha: .18)
              : Colors.transparent,
          alignment: Alignment.center,
          child: Container(
            width: hover ? 2 : 1,
            color: hover
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).dividerColor,
          ),
        ),
      ),
    ),
  );
}
