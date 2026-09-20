/// Provider selection is configuration, never inferred from a socket timeout.
enum CameraProvider {
  basic,
  surround,
  disabled;

  static CameraProvider resolve({
    String? configured,
    Map<Object?, Object?> release = const {},
  }) {
    final value = configured ?? release['camera_mode'];
    return switch (value) {
      null => CameraProvider.basic,
      'basic' || 'legacy' => CameraProvider.basic,
      'surround' || 'external' => CameraProvider.surround,
      'disabled' => CameraProvider.disabled,
      _ => throw FormatException(
        'Unknown camera provider "$value". Choose basic, surround or disabled.',
      ),
    };
  }
}
