import 'package:argo/core/camera/camera_service.dart';
import 'package:argo/core/camera/parking_model_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _Control implements SurroundCameraControl {
  final requests = <String>[];
  @override
  Future<Map<String, dynamic>> command(
    String op, [
    Map<String, Object?> args = const {},
    bool administration = false,
  ]) async {
    requests.add(op);
    if (op == 'worker') return {'job_id': 1};
    if (op == 'job_status') {
      return {
        'state': 'complete',
        'result': {
          'calibration': {
            'cameras': {
              'front': {'marker': 'wrong-camera'},
              'rear': {'marker': 'selected-camera'},
            },
          },
        },
      };
    }
    if (op == 'status') {
      return {
        'camera_modes': {
          'rear': {'width': 640, 'height': 480, 'fps': 30, 'format': 'MJPEG'},
        },
        'streams': [
          {
            'camera_id': 'front',
            'mode': {'width': 1920, 'height': 1080},
          },
          {
            'camera_id': 'rear',
            'mode': {'width': 320, 'height': 240, 'fps': 15, 'format': 'YUYV'},
          },
        ],
      };
    }
    return {};
  }

  @override
  Future<void> selectView(
    String mode, {
    String? group,
    int? width,
    int? height,
  }) async {}
}

void main() {
  test('explicit camera and its actual mode win over first rig camera and saved mode', () async {
    final control = _Control();
    final service = ParkingModelService(control);
    final camera = await service.camera('rear');
    expect(camera!['marker'], 'selected-camera');
    expect(camera['selected_camera_id'], 'rear');
    expect(camera['inference_capture_mode'], {
      'width': 320,
      'height': 240,
      'fps': 15,
      'format': 'YUYV',
      'orientation': 0,
      'crop': null,
    });
    expect(await service.camera('missing'), isNull);
    final count = control.requests.length;
    expect(await service.camera(null), isNull);
    expect(control.requests.length, count);
  });
}
