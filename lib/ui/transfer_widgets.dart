import 'package:flutter/material.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart' as native;

/// Nautilus requests the URI after a drop. The URI is supplied only after the
/// selected remote tree has been fully downloaded into private local staging.
class NativeExportDrag extends StatelessWidget {
  const NativeExportDrag({
    super.key,
    required this.enabled,
    required this.canStart,
    required this.name,
    required this.prepare,
    required this.child,
  });
  final bool enabled;
  final bool Function() canStart;
  final String name;
  final Future<Uri> Function() prepare;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return native.DragItemWidget(
      allowedOperations: () => canStart() ? [native.DropOperation.copy] : [],
      dragItemProvider: (_) {
        if (!canStart()) return null;
        Future<Uri>? prepared;
        final item = native.DragItem(suggestedName: name);
        item.add(native.Formats.fileUri.lazy(() => prepared ??= prepare()));
        return item;
      },
      child: native.DraggableWidget(
        isLocationDraggable: (_) => canStart(),
        child: child,
      ),
    );
  }
}
