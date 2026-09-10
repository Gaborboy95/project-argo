import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Logical viewport allocation only. Host control size and presentation state
/// deliberately cannot participate in video allocation.
class DashboardGeometry {
  DashboardGeometry(Size viewport) {
    final width = viewport.width;
    final height = viewport.height;
    final reservedMedia = math.min(48.0, height * .1);
    dockHeight = math.min(
      height * .4,
      math.min(
        (height * .18).clamp(72.0, 160.0),
        math.max(72.0, height - width * 9 / 16 - reservedMedia),
      ),
    );
    primaryHeight = math.min(
      width * 9 / 16,
      math.max(0, height - dockHeight - reservedMedia),
    );
    mediaHeight = math.min(
      56.0,
      math.max(0, height - dockHeight - primaryHeight),
    );
    dockTop = height - dockHeight;
  }
  static const mediaEdgeGap = 4.0;
  double get closedMediaHeight =>
      (dockTop - primaryHeight - 2 * mediaEdgeGap).clamp(1, double.infinity);
  // Insets are measured from the viewport edge, so include the bottom gap.
  double get mediaSafeHeight => closedMediaHeight + mediaEdgeGap;

  late final double primaryHeight, dockHeight, dockTop, mediaHeight;
}
