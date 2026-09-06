import 'package:flutter/widgets.dart';

/// A local shell layout toggle, not another projection session or surface.
class ProjectionPresentationScope extends InheritedWidget {
  const ProjectionPresentationScope({
    super.key,
    required this.expanded,
    required this.setExpanded,
    required super.child,
  });
  final bool expanded;
  final ValueChanged<bool> setExpanded;

  static ProjectionPresentationScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ProjectionPresentationScope>();
  @override
  bool updateShouldNotify(ProjectionPresentationScope oldWidget) =>
      expanded != oldWidget.expanded;
}
