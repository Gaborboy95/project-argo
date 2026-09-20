/// Metadata-only configuration for the application-owned capture provider.
final class CameraMode {
  const CameraMode(this.width, this.height, this.fps, this.jpeg);
  final int width, height, fps;
  final bool jpeg;
  factory CameraMode.fromJson(Map<String, dynamic> value) {
    final mode = CameraMode(
      value['width'] as int,
      value['height'] as int,
      value['fps'] as int,
      value['jpeg'] as bool,
    );
    if (mode.width < 1 ||
        mode.width > 1920 ||
        mode.height < 1 ||
        mode.height > 1080 ||
        mode.fps < 1 ||
        mode.fps > 30) {
      throw const FormatException('Unsupported camera mode bounds');
    }
    return mode;
  }
  Map<String, Object> toJson() => {
    'width': width,
    'height': height,
    'fps': fps,
    'jpeg': jpeg,
  };
  String get label => '$width × $height · $fps fps · ${jpeg ? 'MJPEG' : 'Raw'}';
  @override
  bool operator ==(Object other) =>
      other is CameraMode &&
      width == other.width &&
      height == other.height &&
      fps == other.fps &&
      jpeg == other.jpeg;
  @override
  int get hashCode => Object.hash(width, height, fps, jpeg);
}

final class BasicCameraConfiguration {
  const BasicCameraConfiguration({
    this.mode,
    this.rotation = 0,
    this.mirror = false,
    this.flip = false,
  });
  final CameraMode? mode;
  final int rotation;
  final bool mirror, flip;
  factory BasicCameraConfiguration.fromJson(Map<String, dynamic> value) {
    final rotation = value['rotation'] as int? ?? 0;
    if (![0, 90, 180, 270].contains(rotation)) {
      throw const FormatException('Invalid camera rotation');
    }
    return BasicCameraConfiguration(
      mode: value['mode'] == null
          ? null
          : CameraMode.fromJson(
              Map<String, dynamic>.from(value['mode'] as Map),
            ),
      rotation: rotation,
      mirror: value['mirror'] as bool? ?? false,
      flip: value['flip'] as bool? ?? false,
    );
  }
  Map<String, Object?> toJson() => {
    'mode': mode?.toJson(),
    'rotation': rotation,
    'mirror': mirror,
    'flip': flip,
  };
}

abstract interface class BasicCameraControl {
  BasicCameraConfiguration get configuration;

  /// Stops capture and proves release before probing. Never substitutes a device.
  Future<List<CameraMode>> discoverModes();
  Future<void> configure(BasicCameraConfiguration configuration);
}
