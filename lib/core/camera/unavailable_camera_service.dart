import 'camera_service.dart';

/// No capture, sockets, retries or data deletion for disabled/missing editions.
final class UnavailableCameraService implements CameraService {
  UnavailableCameraService(String reason)
    : current = CameraSnapshot(error: reason);
  @override
  final CameraSnapshot current;
  @override
  Stream<CameraSnapshot> get changes => const Stream.empty();
  @override
  Future<void> assign(CameraRole role, String stableId) async =>
      throw StateError(current.error!);
  @override
  Future<void> start(CameraRole role) async => throw StateError(current.error!);
  @override
  Future<void> refresh() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> close() async {}
}
