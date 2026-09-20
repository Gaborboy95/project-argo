import 'dart:async';

import 'package:flutter/widgets.dart';

import '../camera_integration.dart';
import '../../core/camera/camera_service.dart';
import '../../core/camera/camera_presentation_policy.dart';
import '../../core/camera/surround_camera_service.dart';
import '../../core/camera/parking_model_service.dart';
import '../../core/settings/settings_service.dart';
import '../../features/camera/surround_camera_page.dart';
import '../../features/settings/models/model_manager_page.dart';

final class SurroundIntegration implements CameraIntegration {
  const SurroundIntegration();
  @override
  CameraService create(
    SettingsService settings,
    Map<String, String> environment,
  ) {
    final service = SurroundCameraService(
      settings: settings,
      environment: environment,
    );
    unawaited(service.initialize());
    return service;
  }

  @override
  void attachPresentation(
    CameraService camera,
    CameraPresentationService presentation,
  ) {
    (camera as SurroundCameraService).renderingMeasurements = () =>
        presentation.renderingMeasurements;
  }

  @override
  Widget cameraPage(CameraService camera) =>
      SurroundCameraPage(service: camera);
  @override
  Widget modelSettings(CameraService camera) => ModelManagerPage(
    canBenchmark: () => camera.current.activeRole == null,
    service: ParkingModelService(camera as SurroundCameraControl),
  );
}
