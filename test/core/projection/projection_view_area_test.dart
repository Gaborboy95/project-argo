import 'package:argo/app/shell/dashboard_geometry.dart';
import 'package:argo/core/projection/projection_preferences.dart';
import 'package:argo/core/projection/projection_touch_mapper.dart';
import 'package:argo/core/projection/projection_types.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'measured View Area fits above dock and reserves overlay in source pixels',
    () {
      final requested = ProjectionPreferences.defaults();
      for (final physical in [
        const Size(800, 600),
        const Size(2000, 1500),
        const Size(2048, 1536),
      ]) {
        for (final dpr in [1.0, 1.25, 2.0]) {
          final viewport = physical / dpr;
          final layout = DashboardGeometry(viewport);
          final overlay = layout.mediaSafeHeight;
          expect(
            overlay,
            layout.closedMediaHeight + DashboardGeometry.mediaEdgeGap,
          );
          final value = requested.forViewport(
            viewport.width,
            layout.dockTop,
            overlay,
          );
          final fitted = ProjectionViewGeometry(
            width: viewport.width,
            height: layout.dockTop,
            devicePixelRatio: dpr,
          ).fit(value.width, value.height, contentInsets: value.viewInsets)!;
          // Even source dimensions may leave less than two source pixels of letterbox.
          expect(
            (fitted.width - viewport.width).abs(),
            lessThan(2 * fitted.width / fitted.sourceWidth + .01),
          );
          expect(
            (fitted.height - layout.dockTop).abs(),
            lessThan(2 * fitted.height / fitted.sourceHeight + .01),
          );
          expect(
            value.safeInsets.bottom * fitted.height / fitted.sourceHeight,
            greaterThanOrEqualTo(overlay),
          );
          expect(
            (value.width, value.height, value.dpi, value.framesPerSecond),
            (1280, 720, 160, 30),
          );
          // Safe insets do not crop video a second time.
          final extraSafe = value.copyWith(
            safeInsets: const ProjectionInsets(bottom: 200),
          );
          expect(extraSafe.viewInsets, value.viewInsets);
          expect(requested.viewInsets, const ProjectionInsets());
        }
      }
    },
  );

  test('manual margins survive fitting; impossible view and safe areas are rejected', () {
    final base = ProjectionPreferences.defaults().copyWith(
      viewInsets: const ProjectionInsets(
        left: 10,
        top: 2,
        right: 12,
        bottom: 4,
      ),
      safeInsets: const ProjectionInsets(left: 5, bottom: 100),
    );
    final fitted = base.forViewport(800, 498, 48);
    expect(fitted.viewInsets.left, greaterThanOrEqualTo(10));
    expect(fitted.viewInsets.right, greaterThanOrEqualTo(12));
    expect(fitted.safeInsets.left, 5);
    expect(fitted.safeInsets.bottom, greaterThanOrEqualTo(100));
    expect(
      () => base.copyWith(viewInsets: const ProjectionInsets(left: 1280)),
      throwsArgumentError,
    );
    expect(
      () => base.copyWith(safeInsets: const ProjectionInsets(bottom: 720)),
      throwsArgumentError,
    );
  });
}
