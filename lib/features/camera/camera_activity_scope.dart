import 'package:flutter/widgets.dart';

/// Retained pages must not infer activity from dispose or a live stream snapshot.
class CameraActivityScope extends InheritedWidget {
  const CameraActivityScope({
    super.key,
    required this.active,
    this.onManualSelection,
    required super.child,
  });
  final bool active;
  final VoidCallback? onManualSelection;
  static void manualSelection(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<CameraActivityScope>()
      ?.onManualSelection
      ?.call();
  static bool activeOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<CameraActivityScope>()
          ?.active ??
      false;
  @override
  bool updateShouldNotify(CameraActivityScope oldWidget) =>
      active != oldWidget.active;
}
