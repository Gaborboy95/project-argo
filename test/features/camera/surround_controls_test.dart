import 'package:argo/core/camera/camera_service.dart';
import 'package:argo/features/camera/recordings_page.dart';
import 'package:argo/features/camera/calibration_wizard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'camera_navigation_test.dart' show CameraFixture;

class CameraControls implements SurroundCameraControl {
  final calls = <Map<String, Object?>>[];
  @override
  Future<Map<String, dynamic>> command(
    String op, [
    Map<String, Object?> args = const {},
    bool admin = false,
  ]) async {
    calls.add({'op': op, ...args});
    return {'state': args['action'] == 'start' ? 'recording' : 'idle'};
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
  for (final encoded in [false, true]) {
    testWidgets(
      'recording UI starts independent tracks (MJPEG=$encoded) and leaving never stops recorder',
      (tester) async {
        final camera = CameraFixture(), control = CameraControls();
        tester.view.physicalSize = const Size(1280, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            home: CameraRecordingsPage(service: camera, control: control),
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(TextField).first,
          '/private/recordings',
        );
        if (encoded) {
          await tester.tap(find.text('Original encoded packets'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Budgeted MJPEG').last);
          await tester.pumpAndSettle();
        }
        await tester.ensureVisible(find.text('Start recording'));
        await tester.tap(find.text('Start recording'));
        await tester.pumpAndSettle();
        final start = control.calls.singleWhere((c) => c['action'] == 'start');
        expect(start['destination'], '/private/recordings');
        expect(start['camera_ids'], ['by-path:port']);
        expect(
          start['encoding_policy'],
          encoded
              ? {
                  'mode': 'mjpeg',
                  'quality': 60,
                  'max_fps_per_camera': 10,
                  'threads': 1,
                  'max_pixels_per_second': 80000000,
                  'queue_bytes': 33554432,
                  'timeout_ms': 750,
                }
              : {'mode': 'passthrough'},
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        expect(control.calls.any((c) => c['action'] == 'stop'), isFalse);
        await camera.close();
      },
    );
  }
  testWidgets(
    'wizard requires physical measurements and never activates an empty candidate',
    (tester) async {
      final camera = CameraFixture(), control = CameraControls();
      tester.view.physicalSize = const Size(1280, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: CalibrationWizard(service: camera, control: control),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Validate measurements'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Enter length m'), findsOneWidget);
      expect(control.calls, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await camera.close();
    },
  );
}
