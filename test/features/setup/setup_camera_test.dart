import 'dart:async';

import 'package:argo/core/camera/basic_camera_control.dart';
import 'package:argo/core/camera/camera_presentation_policy.dart';
import 'package:argo/core/camera/camera_service.dart';
import 'package:argo/features/setup/setup_camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../camera/camera_navigation_test.dart' show CameraFixture;
import '../camera/automatic_camera_navigation_test.dart' show NormalizedVehicle;

class _Camera extends CameraFixture implements BasicCameraControl {
  final started = Completer<void>();
  @override
  BasicCameraConfiguration get configuration =>
      const BasicCameraConfiguration();
  @override
  Future<void> configure(BasicCameraConfiguration value) async {}
  @override
  Future<List<CameraMode>> discoverModes() async => [];
  @override
  Future<void> start(CameraRole role) {
    starts++;
    return started.future;
  }
}

void main() {
  for (final reverse in [false, true]) {
    testWidgets(
      'setup preview disposal preserves replacement reverse=$reverse',
      (tester) async {
        final camera = _Camera(), vehicle = NormalizedVehicle();
        final presentation = CameraPresentationService(vehicle);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: SetupCamera(camera: camera, presentation: presentation),
              ),
            ),
          ),
        );
        expect(camera.starts, 0);
        await tester.tap(find.text('Preview rear camera'));
        await tester.pump();
        expect(camera.starts, 1);
        if (reverse) {
          presentation.current = const CameraPresentationRequest(
            'reverse',
            CameraRole.rear,
          );
        }
        await tester.pumpWidget(const SizedBox());
        expect(camera.stops, reverse ? 0 : 1);
        camera.started.complete();
        await tester.pump();
        expect(camera.stops, reverse ? 0 : 1);
        unawaited(presentation.close());
        unawaited(vehicle.close());
        unawaited(camera.close());
        await tester.pump();
      },
    );
  }
}
