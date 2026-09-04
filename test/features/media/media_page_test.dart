import 'package:argo/core/projection/in_memory_projection_backend.dart';
import 'package:argo/core/projection/projection_models.dart';
import 'package:argo/core/projection/projection_service.dart';
import 'package:argo/core/projection/projection_types.dart';
import 'package:argo/features/media/media_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows safe no-device and connecting states', (tester) async {
    final backend = InMemoryProjectionBackend(
      initial: ProjectionSnapshot(backendAvailable: true),
    );
    final service = _DirectProjectionService(backend);
    await tester.pumpWidget(MaterialApp(home: MediaPage(projection: service)));
    expect(find.text('No device'), findsOneWidget);

    const phone = ProjectionDevice(
      id: 'phone',
      displayName: 'Phone',
      protocol: ProjectionProtocol.androidAuto,
      transport: ProjectionTransport.usb,
    );
    backend.emit(
      ProjectionSnapshot(
        backendAvailable: true,
        devices: const [phone],
        sessions: [
          ProjectionSession(
            id: 'session',
            device: phone,
            state: ProjectionSessionState.connecting,
          ),
        ],
      ),
    );
    await tester.pump();
    expect(find.text('Connecting…'), findsOneWidget);

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
