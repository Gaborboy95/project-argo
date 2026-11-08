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
        const Size(600, 800),
        const Size(768, 1024),
        const Size(1200, 1600),
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
            (value.width, value.height, value.framesPerSecond),
            (1280, 720, 30),
          );
          expect(value.dpi, inInclusiveRange(80, requested.dpi));
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

  test('portrait density uses final content and preserves lower requested DPI', () {
    final requested = ProjectionPreferences.defaults();
    final portrait = requested.forViewport(600, 720, 96);
    expect(1280 - portrait.viewInsets.left - portrait.viewInsets.right, 600);
    expect(portrait.dpi, 131);
    expect(requested.dpi, 160);
    expect(requested.viewInsets, const ProjectionInsets());
    expect(requested.copyWith(dpi: 120).forViewport(600, 720, 96).dpi, 120);
    expect(requested.copyWith(dpi: 80).forViewport(600, 720, 96).dpi, 80);
    for (final size in [(720.0, 600.0), (720.0, 720.0)]) {
      expect(
        requested.copyWith(dpi: 640).forViewport(size.$1, size.$2, 96).dpi,
        640,
      );
    }

    // Saved Safe Area minima can force a wider final rectangle than the host.
    // The decision must use that final content, not the host or encoded aspect.
    final constrained = requested
        .copyWith(
          dpi: 640,
          safeInsets: const ProjectionInsets(left: 400, right: 400),
        )
        .forViewport(600, 720, 0);
    expect(
      1280 - constrained.viewInsets.left - constrained.viewInsets.right,
      801,
    );
    expect(constrained.dpi, 640);
  });

  test('portrait density rounds down at the 730dp threshold and respects protocol floor', () {
    final larger = ProjectionPreferences.defaults().copyWith(
      width: 1920,
      height: 1080,
      dpi: 640,
    );
    expect(larger.forViewport(728, 1080, 0).dpi, 159);
    expect(larger.forViewport(730, 1080, 0).dpi, 160);
    expect(larger.forViewport(732, 1080, 0).dpi, 160);
    final narrow = ProjectionPreferences.defaults().forViewport(364, 720, 0);
    final width =
        narrow.width - narrow.viewInsets.left - narrow.viewInsets.right;
    expect(width, 364);
    expect(narrow.dpi, 80);
    // Below 365 encoded pixels the minimum DPI cannot provide 730 dp.
    expect(width * 160 / narrow.dpi, lessThan(730));
    expect(ProjectionPreferences.defaults().forViewport(366, 720, 0).dpi, 80);
  });

  test(
    'viewport resize retains manual minimums and tolerates transient metrics',
    () {
      final base = ProjectionPreferences.defaults().copyWith(
        safeInsets: const ProjectionInsets(
          left: 300,
          right: 300,
          top: 50,
          bottom: 80,
        ),
      );
      for (final viewport in [(1.0, 1000.0, 999.0), (1000.0, 1.0, 1.0)]) {
        final fitted = base.forViewport(viewport.$1, viewport.$2, viewport.$3);
        expect(fitted.safeInsets.left, 300);
        expect(fitted.safeInsets.right, 300);
        expect(fitted.safeInsets.bottom, greaterThanOrEqualTo(80));
        expect(
          fitted.width - fitted.viewInsets.left - fitted.viewInsets.right,
          greaterThan(fitted.safeInsets.left + fitted.safeInsets.right),
        );
        expect(
          fitted.height - fitted.viewInsets.top - fitted.viewInsets.bottom,
          greaterThan(fitted.safeInsets.top + fitted.safeInsets.bottom),
        );
      }
      for (final viewport in [
        (double.nan, 100.0),
        (100.0, double.infinity),
        (0.0, 100.0),
      ]) {
        expect(base.forViewport(viewport.$1, viewport.$2, 0), same(base));
      }
      final portrait = ProjectionPreferences.defaults().forViewport(
        600,
        680,
        64,
      );
      // Same encoded rectangle as the native CarPlay receiver's 1280x720 tier.
      expect(
        portrait.viewInsets,
        const ProjectionInsets(left: 323, right: 323),
      );
      expect(portrait.safeInsets, const ProjectionInsets(bottom: 68));
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
