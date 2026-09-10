import 'package:flutter/widgets.dart';

/// IndexedStack keeps inactive modules mounted; input ownership is explicit.
class ProjectionInputScope extends InheritedWidget {
  const ProjectionInputScope({
    super.key,
    required this.active,
    this.blocked = false,
    required super.child,
  });
  final bool active;
  final bool blocked;
  static bool blockedOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ProjectionInputScope>()
          ?.blocked ??
      false;

  static bool activeOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ProjectionInputScope>()
          ?.active ??
      true;

  @override
  bool updateShouldNotify(ProjectionInputScope oldWidget) =>
      active != oldWidget.active || blocked != oldWidget.blocked;
}
