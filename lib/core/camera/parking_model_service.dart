import 'camera_service.dart';
import 'surround_jobs.dart';

/// Engine owns catalog, files, downloads and benchmark processes.
final class ParkingModelService {
  ParkingModelService(this.control);
  final SurroundCameraControl control;
  Future<Map<String, dynamic>> request(
    String action, {
    String? id,
    Map<String, dynamic>? camera,
  }) => control.command('models', {
    'action': action,
    'id': ?id,
    'camera': ?camera,
  }, true);

  Future<Map<String, dynamic>?> camera(String? id) async {
    if (id == null) return null;
    final state = await SurroundJob(control)
        .run('calibration', {'op': 'inspect'});
    final calibration = state['calibration'] as Map?;
    final cameras = calibration?['cameras'] as Map?;
    return cameras?[id] is Map
        ? Map<String, dynamic>.from(cameras![id] as Map)
        : null;
  }

  Future<void> start(String cameraId) async {
    final optics = await camera(cameraId);
    final state = await request('status', camera: optics);
    final id = state['selected'] as String?;
    if (id == null) {
      throw StateError('No parking-perception model installed and selected');
    }
    final entry = (state['models'] as List).cast<Map>().firstWhere(
      (e) => e['id'] == id,
    );
    if (entry['compatibility'] != 'Ready') {
      throw StateError('${entry['compatibility']}');
    }
    final model = await request('selected_manifest', id: id);
    await control.command('perception', {
      'action': 'load',
      'manifest': model['manifest'],
    }, true);
    await control.command('perception', {
      'action': 'start',
      'camera_id': cameraId,
      'camera': optics,
    }, true);
  }
}
