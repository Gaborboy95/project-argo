import 'dart:async';

enum CameraRole { rear, front, left, right }

enum CameraStreamState {
  idle,
  starting,
  streaming,
  stale,
  disconnected,
  failed,
}

class CameraDevice {
  const CameraDevice({
    required this.stableId,
    required this.displayName,
    required this.currentVideoNode,
  });
  final String stableId, displayName;

  /// Runtime diagnostics only; never used as a persisted identity.
  final String currentVideoNode;
}

class CameraSnapshot {
  const CameraSnapshot({
    this.available = false,
    this.devices = const [],
    this.assignments = const {},
    this.activeRole,
    this.state = CameraStreamState.idle,
    this.width,
    this.height,
    this.fps,
    this.stride,
    this.sequence = 0,
    this.lastFrame,
    this.error,
    this.external = false,
    this.groups = const {},
    this.details = const {},
  });
  final bool available;
  final bool external;
  final Map<String, List<String>> groups;
  final Map<String, dynamic> details;
  final List<CameraDevice> devices;
  final Map<CameraRole, String> assignments;
  final CameraRole? activeRole;
  final CameraStreamState state;
  final int? width, height, stride;
  final double? fps;
  final int sequence;
  final DateTime? lastFrame;
  final String? error;
  bool get rearUsable =>
      available &&
      devices.any((d) => d.stableId == assignments[CameraRole.rear]);
}

abstract interface class CameraService {
  CameraSnapshot get current;
  Stream<CameraSnapshot> get changes;
  Future<void> assign(CameraRole role, String stableId);
  Future<void> start(CameraRole role);
  Future<void> stop();
  Future<void> refresh();
  Future<void> close();
}

/// Extended administration belongs to the independently managed engine.
/// Values contain metadata only; frames never cross this interface.
abstract interface class SurroundCameraControl {
  Future<Map<String, dynamic>> command(
    String operation, [
    Map<String, Object?> arguments = const {},
    bool administration = false,
  ]);
  Future<void> selectView(String mode, {String? group});
}
