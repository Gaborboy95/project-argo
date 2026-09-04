typedef VehicleSignalDecoder<T> = T Function(Object? value);

/// A stable typed view of one normalized vehicle signal.
final class VehicleSignal<T> {
  VehicleSignal({required this.key, required this.decode}) {
    if (key.length > 256 || !_keyPattern.hasMatch(key)) {
      throw ArgumentError.value(key, 'key', 'Invalid vehicle signal key');
    }
  }

  static final RegExp _keyPattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9_-]*(?:\.[A-Za-z0-9][A-Za-z0-9_-]*)+$',
  );

  final String key;
  final VehicleSignalDecoder<T> decode;
}
