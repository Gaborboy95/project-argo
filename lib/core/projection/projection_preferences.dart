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
    if (!const [
      (800, 480),
      (1280, 720),
      (1920, 1080),
    ].contains((width, height))) {
      throw ArgumentError(
        'Projection dimensions are outside supported bounds.',
      );
    }
    if (dpi < 80 ||
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

  static ProjectionPreferences defaults() => ProjectionPreferences(
    width: 1280,
    height: 720,
    dpi: 160,
    framesPerSecond: 30,
    driverSide: ProjectionDriverSide.left,
    safeInsets: const ProjectionInsets(),
  );
  ProjectionPreferences copyWith({
    int? width,
    int? height,
    int? dpi,
    int? framesPerSecond,
    ProjectionDriverSide? driverSide,
  }) => ProjectionPreferences(
    width: width ?? this.width,
    height: height ?? this.height,
    dpi: dpi ?? this.dpi,
    framesPerSecond: framesPerSecond ?? this.framesPerSecond,
    driverSide: driverSide ?? this.driverSide,
    safeInsets: safeInsets,
  );
  @override
  bool operator ==(Object other) =>
      other is ProjectionPreferences &&
      width == other.width &&
      height == other.height &&
      dpi == other.dpi &&
      framesPerSecond == other.framesPerSecond &&
      driverSide == other.driverSide;
  @override
  int get hashCode =>
      Object.hash(width, height, dpi, framesPerSecond, driverSide);
  @override
  String toString() =>
      '$width×$height, $framesPerSecond FPS, $dpi DPI, ${driverSide.name} driver';

  final int width;
  final int height;
  final int dpi;
  final int framesPerSecond;
  final ProjectionDriverSide driverSide;
  final ProjectionInsets safeInsets;
}
