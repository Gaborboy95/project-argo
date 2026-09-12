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
  });
  final bool available;
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
