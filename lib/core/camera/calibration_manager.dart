import 'camera_service.dart';
import 'surround_jobs.dart';

/// Engine metadata facade. Files, solving and persistent drafts stay outside Argo.
class CalibrationManager {
  CalibrationManager(this.service, this.control);
  final CameraService service;
  final SurroundCameraControl control;
  Future<Map<String, dynamic>> call(
    String op, [
    Map<String, Object?> args = const {},
  ]) => SurroundJob(control).run('calibration', {'op': op, ...args});
  Future<Map<String, dynamic>> capture(String id) =>
      control.command('snapshot', {'camera_id': id}, true);
  Map<String, dynamic> mode(String id) {
    final streams = service.current.details['streams'] as List? ?? [];
    final stream =
        streams.where((s) => s is Map && s['camera_id'] == id).firstOrNull
            as Map?;
    final configured = service.current.details['camera_modes'] as Map? ?? {};
    final mode = Map<String, dynamic>.from(
      stream?['mode'] as Map? ?? configured[id] as Map? ?? {},
    );
    return {
      ...mode,
      'orientation': mode['orientation'] ?? 0,
      'crop': mode['crop'],
    };
  }

  Future<void> present(
    String path,
    int width,
    int height, {
    bool Function()? isCurrent,
  }) async {
    if (isCurrent != null && !isCurrent()) return;
    await control.selectView('direct');
    if (isCurrent != null && !isCurrent()) return;
    await control.command('present', {
      'path': path,
      'timeline': 'replay',
      'width': width,
      'height': height,
    });
  }
}
