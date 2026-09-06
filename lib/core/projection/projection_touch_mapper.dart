import 'projection_models.dart';
import 'projection_types.dart';

final class ProjectionViewGeometry {
  const ProjectionViewGeometry({
    required this.width,
    required this.height,
    this.devicePixelRatio = 1,
    this.preferPhysicalPixels = false,
  });

  final double width;
  final double height;
  final double devicePixelRatio;
  final bool preferPhysicalPixels;

  ProjectionFittedGeometry? fit(int sourceWidth, int sourceHeight) {
    if (!width.isFinite ||
        !height.isFinite ||
        width <= 0 ||
        height <= 0 ||
        !devicePixelRatio.isFinite ||
        devicePixelRatio <= 0 ||
        sourceWidth <= 0 ||
        sourceHeight <= 0) {
      return null;
    }
    var scale = width / sourceWidth < height / sourceHeight
        ? width / sourceWidth
        : height / sourceHeight;
    if (preferPhysicalPixels && scale > 1 / devicePixelRatio) {
      scale = 1 / devicePixelRatio;
    }
    final fittedWidth = sourceWidth * scale;
    final fittedHeight = sourceHeight * scale;
    var left = (width - fittedWidth) / 2;
    var top = (height - fittedHeight) / 2;
    if (preferPhysicalPixels) {
      // Align the 1:1 comparison to physical pixel boundaries when possible.
      left = (left * devicePixelRatio).floorToDouble() / devicePixelRatio;
      top = (top * devicePixelRatio).floorToDouble() / devicePixelRatio;
    }
    return ProjectionFittedGeometry(
      left: left,
      top: top,
      width: fittedWidth,
      height: fittedHeight,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      devicePixelRatio: devicePixelRatio,
    );
  }
}

/// One fitted source rectangle shared by native layout, measurements and input.
final class ProjectionFittedGeometry {
  const ProjectionFittedGeometry({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.devicePixelRatio,
  });
  final double left, top, width, height, devicePixelRatio;
  final int sourceWidth, sourceHeight;
  double get physicalWidth => width * devicePixelRatio;
  double get physicalHeight => height * devicePixelRatio;
  double get scaleX => physicalWidth / sourceWidth;
  double get scaleY => physicalHeight / sourceHeight;
  bool get isOneToOne =>
      (physicalWidth - sourceWidth).abs() < 0.01 &&
      (physicalHeight - sourceHeight).abs() < 0.01;
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
    final fitted = view.fit(stream.width, stream.height);
    if (fitted == null) return null;
    final scale = fitted.width / sourceWidth;
    final sourceX = (localX - fitted.left) / scale;
    final sourceY = (localY - fitted.top) / scale;

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
}
