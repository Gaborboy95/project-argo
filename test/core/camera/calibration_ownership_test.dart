import 'dart:async';

import 'package:argo/core/camera/calibration_manager.dart';
import 'package:argo/core/camera/camera_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../features/camera/camera_navigation_test.dart' show CameraFixture;

class _Control implements SurroundCameraControl {
  final status = Completer<Map<String, dynamic>>();
  final view = Completer<void>();
  final polled = Completer<void>();
  final calls = <String>[];
  @override
  Future<Map<String, dynamic>> command(
    String op, [
    Map<String, Object?> args = const {},
    bool administration = false,
  ]) async {
    calls.add(op);
    if (op == 'worker') return {'job_id': 1};
    if (op == 'job_status') {
      if (!polled.isCompleted) polled.complete();
      return status.future;
    }
    return {};
  }

  @override
  Future<void> selectView(
    String mode, {
    String? group,
    int? width,
    int? height,
  }) => view.future;
}

void main() {
  test(
    'closed view rejects late solver result and cancels owned job',
    () async {
      final control = _Control(), service = CameraFixture();
      final manager = CalibrationManager(service, control);
      final pending = manager.call('draft_solve');
      final rejected = expectLater(pending, throwsStateError);
      await control.polled.future;
      await manager.close();
      control.status.complete({
        'state': 'complete',
        'result': {'draft': {}},
      });
      await rejected;
      expect(control.calls, contains('cancel'));
      await expectLater(manager.call('draft_get'), throwsStateError);
      await service.close();
    },
  );
  test(
    'closed view cannot publish image after delayed view selection',
    () async {
      final control = _Control(), service = CameraFixture();
      final manager = CalibrationManager(service, control);
      final pending = manager.present('/fixture', 320, 240);
      await manager.close();
      control.view.complete();
      await pending;
      expect(control.calls, isNot(contains('present')));
      await service.close();
    },
  );
}
