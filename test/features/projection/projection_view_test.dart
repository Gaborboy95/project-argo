import 'package:argo/core/projection/in_memory_projection_backend.dart';
import 'package:argo/core/projection/projection_models.dart';
import 'package:argo/core/projection/projection_service.dart';
import 'package:argo/core/projection/projection_types.dart';
import 'package:argo/features/projection/projection_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('projection view maps valid pointer input through service', (
    tester,
  ) async {
    final backend = InMemoryProjectionBackend();
    final service = _DirectProjectionService(backend);
    final stream = ProjectionVideoStream(
      id: 'main',
      sessionId: 'session',
      role: ProjectionVideoRole.main,
      codec: ProjectionVideoCodec.h264,
      width: 1280,
      height: 720,
      framesPerSecond: 30,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 640,
            height: 360,
            child: ProjectionView(
              service: service,
              sessionId: 'session',
              stream: stream,
              nativeViewBuilder: (_, _) =>
                  const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ProjectionView)),
    );
    await gesture.up();
    await tester.pump();

    expect(backend.touches.map((touch) => touch.phase), [
      ProjectionTouchPhase.down,
      ProjectionTouchPhase.up,
    ]);
    expect(backend.touches.first.x, closeTo(0.5, 0.01));
    await tester.pumpWidget(const SizedBox());
    await backend.close();
  });
}

final class _DirectProjectionService implements ProjectionService {
  _DirectProjectionService(this.backend);
  final InMemoryProjectionBackend backend;
  @override
  ProjectionSnapshot get current => backend.current;
  @override
  Stream<ProjectionSnapshot> get changes => backend.changes;
  @override
  Future<void> activate(String sessionId) => backend.activate(sessionId);
  @override
  Future<void> close() => backend.close();
  @override
  Future<void> connect(String deviceId) => backend.connect(deviceId);
  @override
  Future<void> disconnect(String sessionId) => backend.disconnect(sessionId);
  @override
  Future<void> sendButton(
    String sessionId,
    ProjectionInputButton button, {
    required bool pressed,
  }) => backend.sendButton(sessionId, button, pressed: pressed);
  @override
  Future<void> sendRotary(String sessionId, int detents) =>
      backend.sendRotary(sessionId, detents);
  @override
  Future<void> sendTouch(String sessionId, ProjectionTouch touch) =>
      backend.sendTouch(sessionId, touch);
  @override
  Future<void> setVideoVisibility(String streamId, bool visible) =>
      backend.setVideoVisibility(streamId, visible);
}
