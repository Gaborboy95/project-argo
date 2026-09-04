import '../settings/app_setting_keys.dart';
import '../settings/settings_service.dart';
import 'projection_types.dart';

final class ProjectionPreferences {
  ProjectionPreferences({
    required this.width,
    required this.height,
    required this.dpi,
    required this.framesPerSecond,
    required this.driverSide,
    required this.safeInsets,
  }) {
    if (width < 640 || width > 3840 || height < 360 || height > 2160) {
      throw ArgumentError(
        'Projection dimensions are outside supported bounds.',
      );
    }
    if (dpi < 72 ||
        dpi > 640 ||
        (framesPerSecond != 30 && framesPerSecond != 60)) {
      throw ArgumentError('Projection DPI or FPS is outside supported bounds.');
    }
    safeInsets.validate(name: 'safeInsets');
  }

  factory ProjectionPreferences.fromSettings(
    SettingsService settings,
  ) => ProjectionPreferences(
    width: settings.get(AppSettingKeys.projectionDisplayWidth),
    height: settings.get(AppSettingKeys.projectionDisplayHeight),
    dpi: settings.get(AppSettingKeys.projectionDisplayDpi),
    framesPerSecond: settings.get(AppSettingKeys.projectionFramesPerSecond),
    driverSide: settings.get(AppSettingKeys.projectionDriverSide) == 'right'
        ? ProjectionDriverSide.right
        : ProjectionDriverSide.left,
    safeInsets: ProjectionInsets(
      left: settings.get(AppSettingKeys.projectionSafeInsetLeft).toDouble(),
      top: settings.get(AppSettingKeys.projectionSafeInsetTop).toDouble(),
      right: settings.get(AppSettingKeys.projectionSafeInsetRight).toDouble(),
      bottom: settings.get(AppSettingKeys.projectionSafeInsetBottom).toDouble(),
    ),
  );

  final int width;
  final int height;
  final int dpi;
  final int framesPerSecond;
  final ProjectionDriverSide driverSide;
  final ProjectionInsets safeInsets;
}
