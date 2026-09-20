import 'package:flutter/widgets.dart';

import '../core/camera/camera_service.dart';
import '../core/camera/camera_presentation_policy.dart';
import '../core/settings/settings_service.dart';

/// Injected at an edition entrypoint. The standard graph imports only this contract.
abstract interface class CameraIntegration {
  CameraService create(
    SettingsService settings,
    Map<String, String> environment,
  );
  void attachPresentation(
    CameraService camera,
    CameraPresentationService presentation,
  );
  Widget cameraPage(CameraService camera);
  Widget modelSettings(CameraService camera);
}

final class CameraFeatureContribution {
  const CameraFeatureContribution({required this.page, this.settings});
  final Widget page;
  final Widget? settings;
}
