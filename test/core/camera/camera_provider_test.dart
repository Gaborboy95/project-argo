import 'package:argo/core/camera/camera_provider.dart';
import 'package:argo/core/camera/basic_camera_control.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('basic is default and aliases preserve explicit existing selection', () {
    expect(CameraProvider.resolve(), CameraProvider.basic);
    for (final name in ['basic', 'legacy']) {
      expect(CameraProvider.resolve(configured: name), CameraProvider.basic);
    }
    for (final name in ['surround', 'external']) {
      expect(
        CameraProvider.resolve(release: {'camera_mode': name}),
        CameraProvider.surround,
      );
    }
    expect(
      CameraProvider.resolve(configured: 'disabled'),
      CameraProvider.disabled,
    );
    expect(
      () => CameraProvider.resolve(configured: 'typo'),
      throwsFormatException,
    );
    expect(
      () => CameraProvider.resolve(release: {'camera_mode': 'typo'}),
      throwsFormatException,
    );
  });
  test(
    'configuration round trips exact advertised choice and rejects bad bounds',
    () {
      const value = BasicCameraConfiguration(
        mode: CameraMode(1280, 720, 25, true),
        rotation: 270,
        mirror: true,
      );
      final decoded = BasicCameraConfiguration.fromJson(value.toJson());
      expect(decoded.mode, value.mode);
      expect(decoded.rotation, 270);
      expect(decoded.mirror, isTrue);
      expect(
        () => BasicCameraConfiguration.fromJson({'rotation': 45}),
        throwsFormatException,
      );
      expect(
        () => CameraMode.fromJson({
          'width': 4096,
          'height': 1080,
          'fps': 30,
          'jpeg': false,
        }),
        throwsFormatException,
      );
    },
  );
}
