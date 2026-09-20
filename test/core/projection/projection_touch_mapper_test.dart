import 'package:argo/core/projection/projection_models.dart';
import 'package:argo/core/projection/projection_touch_mapper.dart';
import 'package:argo/core/projection/projection_types.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final stream = ProjectionVideoStream(
    id: 'main',
    sessionId: 'session',
    role: ProjectionVideoRole.main,
    codec: ProjectionVideoCodec.h264,
    width: 1280,
    height: 720,
    framesPerSecond: 30,
    contentInsets: const ProjectionInsets(left: 80, right: 80),
  );
  const mapper = ProjectionTouchMapper();

  test('maps content coordinates after letterbox and view-area offsets', () {
    final touch = mapper.map(
      stream: stream,
      view: const ProjectionViewGeometry(width: 1000, height: 1000),
      pointerId: 7,
      phase: ProjectionTouchPhase.down,
      localX: 500,
      localY: 500,
    );

    expect(touch, isNotNull);
    expect(touch!.pointerId, 7);
    expect(touch.x, closeTo(0.5, 0.0001));
    expect(touch.y, closeTo(0.5, 0.0001));
  });

  test(
    'shared input uses the fitted crop across DPR and viewport orientation',
    () {
      final cropped = ProjectionVideoStream(
        id: 'main',
        sessionId: 'session',
        role: ProjectionVideoRole.main,
        codec: ProjectionVideoCodec.h264,
        width: 1920,
        height: 1080,
        framesPerSecond: 60,
        contentInsets: const ProjectionInsets(
          left: 40,
          top: 20,
          right: 80,
          bottom: 40,
        ),
        // Safe insets guide the phone UI and must not crop or rescale input again.
        safeInsets: const ProjectionInsets(left: 100, bottom: 160),
      );
      for (final viewport in [(1000.0, 600.0), (600.0, 1000.0)]) {
        for (final dpr in [1.0, 1.25, 2.5]) {
          final view = ProjectionViewGeometry(
            width: viewport.$1,
            height: viewport.$2,
            devicePixelRatio: dpr,
          );
          final fit = view.fit(
            1920,
            1080,
            contentInsets: cropped.contentInsets,
          )!;
          expect((fit.sourceWidth, fit.sourceHeight), (1800, 1020));
          for (final point in [(0.0, 0.0), (.25, .75), (.999, .999)]) {
            final touch = mapper.map(
              stream: cropped,
              view: view,
              pointerId: 9,
              phase: ProjectionTouchPhase.move,
              localX: fit.left + point.$1 * fit.width,
              localY: fit.top + point.$2 * fit.height,
            )!;
            expect(touch.x, closeTo(point.$1, 1e-8));
            expect(touch.y, closeTo(point.$2, 1e-8));
          }
          expect(
            mapper.map(
              stream: cropped,
              view: view,
              pointerId: 9,
              phase: ProjectionTouchPhase.down,
              localX: fit.left - 0.1,
              localY: fit.top + fit.height / 2,
            ),
            isNull,
          );
        }
      }
    },
  );

  test('suppresses touches in letterbox and outside phone content', () {
    expect(
      mapper.map(
        stream: stream,
        view: const ProjectionViewGeometry(width: 1000, height: 1000),
        pointerId: 1,
        phase: ProjectionTouchPhase.down,
        localX: 500,
        localY: 20,
      ),
      isNull,
    );
    expect(
      mapper.map(
        stream: stream,
        view: const ProjectionViewGeometry(width: 1280, height: 720),
        pointerId: 1,
        phase: ProjectionTouchPhase.down,
        localX: 20,
        localY: 300,
      ),
      isNull,
    );
  });
}
