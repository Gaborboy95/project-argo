import 'package:flutter/widgets.dart';

/// IndexedStack keeps inactive modules mounted; input ownership is explicit.
class ProjectionInputScope extends InheritedWidget {
  const ProjectionInputScope({
    super.key,
    required this.active,
    required super.child,
  });
  final bool active;

  static bool activeOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ProjectionInputScope>()
          ?.active ??
      true;

  @override
  bool updateShouldNotify(ProjectionInputScope oldWidget) =>
      active != oldWidget.active;
}
