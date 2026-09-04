import 'vehicle_signal.dart';

/// The intentionally small catalog of normalized signals used by Argo.
abstract final class VehicleSignals {
  static final engineRpm = VehicleSignal<double>(
    key: 'engine.rpm',
    decode: (value) {
      if (value is num) {
        final rpm = value.toDouble();
        if (rpm.isFinite) return rpm;
      }
      throw FormatException(
        'engine.rpm must be a finite integer or double, got '
        '${value.runtimeType}.',
      );
    },
  );
}
