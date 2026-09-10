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
    this.viewInsets = const ProjectionInsets(),
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
    viewInsets.validate(name: 'viewInsets');
    if (viewInsets.left + viewInsets.right >= width - 1 ||
        viewInsets.top + viewInsets.bottom >= height - 1 ||
        safeInsets.left + safeInsets.right >=
            width - viewInsets.left - viewInsets.right ||
        safeInsets.top + safeInsets.bottom >=
            height - viewInsets.top - viewInsets.bottom) {
      throw ArgumentError(
        'View Area and Safe Area must leave visible content.',
      );
    }
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
    viewInsets: ProjectionInsets(
      left: settings.get(AppSettingKeys.projectionViewInsetLeft).toDouble(),
      top: settings.get(AppSettingKeys.projectionViewInsetTop).toDouble(),
      right: settings.get(AppSettingKeys.projectionViewInsetRight).toDouble(),
      bottom: settings.get(AppSettingKeys.projectionViewInsetBottom).toDouble(),
    ),
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
    ProjectionInsets? viewInsets,
    ProjectionInsets? safeInsets,
  }) => ProjectionPreferences(
    width: width ?? this.width,
    height: height ?? this.height,
    dpi: dpi ?? this.dpi,
    framesPerSecond: framesPerSecond ?? this.framesPerSecond,
    driverSide: driverSide ?? this.driverSide,
    safeInsets: safeInsets ?? this.safeInsets,
    viewInsets: viewInsets ?? this.viewInsets,
  );

  /// Fit the negotiated content rectangle, not an arbitrary crop of phone UI.
  ProjectionPreferences forViewport(
    double viewportWidth,
    double viewportHeight,
    double overlayHeight,
  ) {
    if (viewportWidth <= 0 || viewportHeight <= 0) return this;
    var left = viewInsets.left.toInt(), right = viewInsets.right.toInt();
    var top = viewInsets.top.toInt(), bottom = viewInsets.bottom.toInt();
    final availableW = width - left - right, availableH = height - top - bottom;
    final aspect = viewportWidth / viewportHeight;
    if (availableW / availableH > aspect) {
      final content = (availableH * aspect).floor().clamp(2, availableW) & ~1;
      final margin = availableW - content;
      left += margin ~/ 2;
      right += margin - margin ~/ 2;
    } else {
      final content = (availableW / aspect).floor().clamp(2, availableH) & ~1;
      final margin = availableH - content;
      top += margin ~/ 2;
      bottom += margin - margin ~/ 2;
    }
    final scaleY = viewportHeight / (height - top - bottom);
    final scaleX = viewportWidth / (width - left - right);
    final scale = scaleX < scaleY ? scaleX : scaleY;
    final reserve = (overlayHeight / scale).ceilToDouble();
    return copyWith(
      viewInsets: ProjectionInsets(
        left: left.toDouble(),
        top: top.toDouble(),
        right: right.toDouble(),
        bottom: bottom.toDouble(),
      ),
      safeInsets: ProjectionInsets(
        left: safeInsets.left,
        top: safeInsets.top,
        right: safeInsets.right,
        bottom: reserve > safeInsets.bottom ? reserve : safeInsets.bottom,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ProjectionPreferences &&
      width == other.width &&
      height == other.height &&
      dpi == other.dpi &&
      framesPerSecond == other.framesPerSecond &&
      driverSide == other.driverSide &&
      safeInsets == other.safeInsets &&
      viewInsets == other.viewInsets;
  @override
  int get hashCode => Object.hash(
    width,
    height,
    dpi,
    framesPerSecond,
    driverSide,
    viewInsets,
    safeInsets,
  );
  @override
  String toString() =>
      '$width×$height, $framesPerSecond FPS, $dpi DPI, ${driverSide.name} driver';

  final ProjectionInsets viewInsets;
  final int width;
  final int height;
  final int dpi;
  final int framesPerSecond;
  final ProjectionDriverSide driverSide;
  final ProjectionInsets safeInsets;
}
