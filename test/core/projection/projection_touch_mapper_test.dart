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
