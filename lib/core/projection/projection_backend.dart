import 'projection_models.dart';
import 'projection_types.dart';

abstract interface class ProjectionBackend {
  ProjectionProtocol? get protocol;
  ProjectionSnapshot get current;
  Stream<ProjectionSnapshot> get changes;

  Future<void> start();
  Future<void> connect(String deviceId);
  Future<void> disconnect(String sessionId);
  Future<void> activate(String sessionId);
  Future<void> sendTouch(String sessionId, ProjectionTouch touch);
  Future<void> sendButton(
    String sessionId,
    ProjectionInputButton button, {
    required bool pressed,
  });
  Future<void> sendRotary(String sessionId, int detents);
  Future<void> setVideoVisibility(String streamId, bool visible);
  Future<void> close();
}
