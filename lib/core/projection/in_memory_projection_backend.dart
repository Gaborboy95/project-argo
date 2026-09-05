import 'dart:async';

import 'projection_backend.dart';
import 'projection_models.dart';
import 'projection_types.dart';

final class InMemoryProjectionBackend implements ProjectionBackend {
  InMemoryProjectionBackend({
    this.protocol = ProjectionProtocol.androidAuto,
    ProjectionSnapshot? initial,
  }) : _current = initial ?? ProjectionSnapshot(backendAvailable: true);

  @override
  final ProjectionProtocol protocol;
  final StreamController<ProjectionSnapshot> _changes =
      StreamController<ProjectionSnapshot>.broadcast(sync: true);
  ProjectionSnapshot _current;
  final List<ProjectionTouch> touches = [];
  final List<(ProjectionInputButton, bool)> buttons = [];
  final List<int> rotaryDetents = [];
  bool closed = false;

  @override
  ProjectionSnapshot get current => _current;
  @override
  Stream<ProjectionSnapshot> get changes => _changes.stream;

  void emit(ProjectionSnapshot snapshot) {
    if (closed) throw StateError('Projection backend is closed.');
    if (snapshot == _current) return;
    _current = snapshot;
    _changes.add(snapshot);
  }

  @override
  Future<void> start() async {}
  @override
  Future<void> connect(String deviceId) async {}
  @override
  Future<void> disconnect(String sessionId) async {}
  @override
  Future<void> activate(String sessionId) async {}
  @override
  Future<void> sendTouch(String sessionId, ProjectionTouch touch) async =>
      touches.add(touch);
  @override
  Future<void> sendButton(
    String sessionId,
    ProjectionInputButton button, {
    required bool pressed,
  }) async => buttons.add((button, pressed));
  @override
  Future<void> sendRotary(String sessionId, int detents) async =>
      rotaryDetents.add(detents);
  @override
  Future<void> setVideoVisibility(String streamId, bool visible) async {}
  final Map<String, double> audioGains = {};
  @override
  Future<void> setAudioGain(
    String sessionId,
    String streamId,
    double gain,
  ) async {
    audioGains['$sessionId/$streamId'] = gain;
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await _changes.close();
  }
}
