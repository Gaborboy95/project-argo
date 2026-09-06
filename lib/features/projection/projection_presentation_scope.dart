import 'package:flutter/widgets.dart';

/// Application-owned presentation readiness. Neither the service nor native view
/// knows which Argo destination owns presentation.
class ProjectionPresentationScope extends InheritedWidget {
  const ProjectionPresentationScope({
    super.key,
    required this.waiting,
    this.error,
    required super.child,
  });
  final bool waiting;
  final String? error;

  static ProjectionPresentationScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ProjectionPresentationScope>();
  @override
  bool updateShouldNotify(ProjectionPresentationScope oldWidget) =>
      waiting != oldWidget.waiting || error != oldWidget.error;
}
