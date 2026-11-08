import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Logical viewport allocation only. Host control size and presentation state
/// deliberately cannot participate in video allocation.
class DashboardGeometry {
  DashboardGeometry(Size viewport) {
    final width = viewport.width;
    final height = viewport.height;
    final reservedMedia = math.min(48.0, height * .1);
    final portrait = height > width;
    if (portrait) {
      dockHeight = math.min(height * .4, (height * .18).clamp(136.0, 160.0));
    } else {
      dockHeight = math.min(
        height * .4,
        math.min(
          (height * .18).clamp(72.0, 160.0),
          math.max(72.0, height - width * 9 / 16 - reservedMedia),
        ),
      );
    }
    dockTop = height - dockHeight;
    // A readable compact player, bounded in short windows. This reserve is
    // independent of media visibility, so toggling it never renegotiates video.
    final playerHeight = math.min(compactMediaHeight, dockTop * .35);
    mediaHeight = math.min(dockTop, playerHeight + 2 * mediaEdgeGap);
    primaryHeight = math.max(0, dockTop - mediaHeight);
  }
  static const mediaEdgeGap = 4.0;
  static const compactMediaHeight = 96.0;
  double get closedMediaHeight =>
      (dockTop - primaryHeight - 2 * mediaEdgeGap).clamp(1, double.infinity);
  // Insets are measured from the viewport edge, so include the bottom gap.
  double get mediaSafeHeight => closedMediaHeight + mediaEdgeGap;

  late final double primaryHeight, dockHeight, dockTop, mediaHeight;
}
