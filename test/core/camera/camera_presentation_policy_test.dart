import 'package:argo/core/camera/camera_presentation_policy.dart';
import 'package:argo/core/camera/camera_service.dart';
import 'package:flutter_test/flutter_test.dart';

CameraSignalValue<T> value<T>(T value, int ms) =>
    CameraSignalValue(value, Duration(milliseconds: ms));
void main() {
  test('reverse has priority over PDC and both indicators', () {
    final policy = CameraPresentationPolicy(sideViews: true)
      ..reverse = value(true, 0)
      ..pdc = value(true, 0)
      ..left = value(true, 0)
      ..right = value(true, 0)
      ..speed = value(0.0, 0);
    expect(policy.evaluate(Duration.zero)?.role, CameraRole.rear);
    policy.reverse = value(false, 100);
    expect(
      policy.evaluate(const Duration(milliseconds: 100))?.role,
      CameraRole.front,
    );
  });
  test('speed unknown suppresses optional views; hysteresis prevents threshold oscillation', () {
    final policy = CameraPresentationPolicy()..pdc = value(true, 0);
    expect(policy.evaluate(Duration.zero), isNull);
    policy.speed = value(2.9, 0);
    expect(policy.evaluate(Duration.zero)?.role, CameraRole.front);
    policy.speed = value(3.5, 100);
    expect(
      policy.evaluate(const Duration(milliseconds: 100))?.role,
      CameraRole.front,
    );
    policy.speed = value(4.1, 200);
    expect(
      policy.evaluate(const Duration(milliseconds: 200))?.role,
      CameraRole.front,
    );
    expect(policy.evaluate(const Duration(milliseconds: 1001)), isNull);
  });
  test('hazards never alternate side requests and old observations expire independently', () {
    final policy = CameraPresentationPolicy(sideViews: true)
      ..left = value(true, 0)
      ..right = value(false, 0)
      ..speed = value(1.0, 0);
    expect(policy.evaluate(Duration.zero)?.role, CameraRole.left);
    policy.right = value(true, 30);
    expect(policy.evaluate(const Duration(milliseconds: 30)), isNull);
    expect(policy.evaluate(const Duration(milliseconds: 2000)), isNull);
  });
  test(
    'manual navigation cancels ownership until the originating request ends',
    () {
      final policy = CameraPresentationPolicy()..reverse = value(true, 0);
      expect(policy.evaluate(Duration.zero)?.owner, 'reverse');
      policy.manualSelection();
      expect(policy.evaluate(const Duration(milliseconds: 20)), isNull);
      policy.reverse = value(false, 30);
      expect(policy.evaluate(const Duration(milliseconds: 30)), isNull);
      policy.reverse = value(true, 50);
      expect(
        policy.evaluate(const Duration(milliseconds: 50))?.owner,
        'reverse',
      );
    },
  );
  test(
    'unknown or future source stamps cannot refresh a stale automatic view',
    () {
      final policy = CameraPresentationPolicy()..reverse = value(true, 100);
      expect(policy.evaluate(Duration.zero), isNull);
      expect(
        policy.evaluate(const Duration(milliseconds: 100))?.owner,
        'reverse',
      );
      expect(policy.evaluate(const Duration(milliseconds: 901)), isNull);
    },
  );
}
