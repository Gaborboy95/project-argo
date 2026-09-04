import 'projection_models.dart';
import 'projection_types.dart';

final class ProjectionViewGeometry {
  const ProjectionViewGeometry({required this.width, required this.height});

  final double width;
  final double height;
}

/// Maps view-local Flutter coordinates into the active phone content region.
final class ProjectionTouchMapper {
  const ProjectionTouchMapper();

  ProjectionTouch? map({
    required ProjectionVideoStream stream,
    required ProjectionViewGeometry view,
    required int pointerId,
    required ProjectionTouchPhase phase,
    required double localX,
    required double localY,
  }) {
    if (!view.width.isFinite ||
        !view.height.isFinite ||
        view.width <= 0 ||
        view.height <= 0 ||
        !localX.isFinite ||
        !localY.isFinite) {
      return null;
    }

    final sourceWidth = stream.width.toDouble();
    final sourceHeight = stream.height.toDouble();
    final scale = _min(view.width / sourceWidth, view.height / sourceHeight);
    final renderedWidth = sourceWidth * scale;
    final renderedHeight = sourceHeight * scale;
    final offsetX = (view.width - renderedWidth) / 2;
    final offsetY = (view.height - renderedHeight) / 2;
    final sourceX = (localX - offsetX) / scale;
    final sourceY = (localY - offsetY) / scale;

    final content = stream.contentInsets;
    final contentWidth = sourceWidth - content.left - content.right;
    final contentHeight = sourceHeight - content.top - content.bottom;
    final contentX = sourceX - content.left;
    final contentY = sourceY - content.top;
    if (contentX < 0 ||
        contentY < 0 ||
        contentX >= contentWidth ||
        contentY >= contentHeight) {
      return null;
    }

    final touch = ProjectionTouch(
      pointerId: pointerId,
      phase: phase,
      x: (contentX / contentWidth).clamp(0.0, 1.0),
      y: (contentY / contentHeight).clamp(0.0, 1.0),
    );
    touch.validate();
    return touch;
  }

  static double _min(double left, double right) => left < right ? left : right;
}
