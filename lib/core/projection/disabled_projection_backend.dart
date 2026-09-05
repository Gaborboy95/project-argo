import 'projection_backend.dart';
import 'projection_models.dart';
import 'projection_types.dart';

final class DisabledProjectionBackend implements ProjectionBackend {
  const DisabledProjectionBackend();

  @override
  ProjectionProtocol? get protocol => null;

  @override
  ProjectionSnapshot get current => const ProjectionSnapshot.disabled();

  @override
  Stream<ProjectionSnapshot> get changes => const Stream.empty();

  @override
  Future<void> start() async {}

  Never _disabled() => throw StateError('Projection backend is disabled.');

  @override
  Future<void> activate(String sessionId) async => _disabled();
  @override
  Future<void> connect(String deviceId) async => _disabled();
  @override
  Future<void> disconnect(String sessionId) async => _disabled();
  @override
  Future<void> sendButton(
    String sessionId,
    ProjectionInputButton button, {
    required bool pressed,
  }) async => _disabled();
  @override
  Future<void> sendRotary(String sessionId, int detents) async => _disabled();
  @override
  Future<void> sendTouch(String sessionId, ProjectionTouch touch) async =>
      _disabled();
  @override
  Future<void> setVideoVisibility(String streamId, bool visible) async =>
      _disabled();

  @override
  Future<void> close() async {}
  @override
  Future<void> setAudioGain(
    String sessionId,
    String streamId,
    double gain,
  ) async => _disabled();
}
