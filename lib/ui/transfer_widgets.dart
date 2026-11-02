import 'package:flutter/material.dart';

class FileDrag {
  const FileDrag({required this.paths, required this.local, this.session});
  final List<String> paths;
  final bool local;
  final Object? session;
}

class TransferDrag extends StatelessWidget {
  const TransferDrag({
    super.key,
    required this.data,
    required this.name,
    required this.directory,
    required this.enabled,
    required this.child,
  });
  final FileDrag data;
  final String name;
  final bool directory;
  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) => Draggable<FileDrag>(
    data: data,
    maxSimultaneousDrags: enabled ? 1 : 0,
    dragAnchorStrategy: pointerDragAnchorStrategy,
    feedback: Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(8),
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              directory ? Icons.folder : Icons.insert_drive_file_outlined,
              size: 18,
            ),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(
                name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ),
            const SizedBox(width: 12),
            const Icon(Icons.copy, size: 14),
          ],
        ),
      ),
    ),
    childWhenDragging: Opacity(opacity: .4, child: child),
    child: child,
  );
}

class TransferTarget extends StatelessWidget {
  const TransferTarget({
    super.key,
    required this.accepts,
    required this.onDrop,
    required this.label,
    required this.child,
  });
  final bool Function(FileDrag) accepts;
  final Future<void> Function(FileDrag) onDrop;
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => DragTarget<FileDrag>(
    onWillAcceptWithDetails: (details) => accepts(details.data),
    onAcceptWithDetails: (details) {
      onDrop(details.data);
    },
    builder: (context, candidates, rejected) => Stack(
      fit: StackFit.passthrough,
      children: [
        child,
        if (candidates.isNotEmpty)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary
                      .withValues(alpha: .12),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.primary,
                    width: 2,
                  ),
                ),
                alignment: Alignment.center,
                child: Container(
                  padding: const EdgeInsets.all(8),
                  color: Theme.of(context).colorScheme.surface,
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}
