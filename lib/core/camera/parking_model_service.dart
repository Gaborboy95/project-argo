import 'camera_service.dart';
import 'surround_jobs.dart';

enum ParkingModelState {
  notInstalled('Not installed'),
  downloading('Downloading'),
  installed('Installed'),
  verified('Verified'),
  incompatible('Incompatible with selected camera'),
  ready('Ready'),
  running('Running'),
  benchmarking('Benchmarking'),
  failed('Failed');

  const ParkingModelState(this.label);
  final String label;
  static ParkingModelState fromRecord(Map model) => switch (model['state']) {
    'not_installed' => notInstalled,
    'downloading' => downloading,
    'installed' => installed,
    'verified' => verified,
    'incompatible' => incompatible,
    'ready' => ready,
    'running' => running,
    'benchmarking' => benchmarking,
    'failed' => failed,
    _ => model['installed'] == true ? installed : notInstalled,
  };
}

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
    if (cameras?[id] is! Map) return null;
    final status = await control.command('status');
    final streams = status['streams'] as List? ?? [];
    final stream =
        streams.where((s) => s is Map && s['camera_id'] == id).firstOrNull
            as Map?;
    final configured = status['camera_modes'] as Map? ?? {};
    final mode = Map<String, dynamic>.from(
      stream?['mode'] as Map? ?? configured[id] as Map? ?? {},
    );
    return {
      ...Map<String, dynamic>.from(cameras![id] as Map),
      'selected_camera_id': id,
      // The external capture contract currently publishes uncropped orientation 0.
      // Unknown mode stays unknown and cannot be inferred from another camera.
      'inference_capture_mode': {...mode, 'orientation': 0, 'crop': null},
    };
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
