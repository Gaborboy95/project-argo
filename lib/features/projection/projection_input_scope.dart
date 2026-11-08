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
  static bool blockedOf(BuildContext context) {
    var blocked = false;
    // A global modal must still block a retained projection page whose local
    // scope independently owns navigation. Subscribe to every blocking scope.
    context.visitAncestorElements((element) {
      if (element is InheritedElement &&
          element.widget is ProjectionInputScope) {
        context.dependOnInheritedElement(element);
        blocked = (element.widget as ProjectionInputScope).blocked;
      }
      return !blocked;
    });
    return blocked;
  }

  static bool activeOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ProjectionInputScope>()
          ?.active ??
      true;

  @override
  bool updateShouldNotify(ProjectionInputScope oldWidget) =>
      active != oldWidget.active || blocked != oldWidget.blocked;
}
