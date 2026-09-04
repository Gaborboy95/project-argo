import 'vehicle_signal.dart';
import 'vehicle_ignition_state.dart';
import 'vehicle_power_state.dart';

/// The intentionally small catalog of normalized signals used by Argo.
abstract final class VehicleSignals {
  static final engineRpm = VehicleSignal<double>(
    key: 'engine.rpm',
    decode: _finiteDouble('engine.rpm'),
  );

  static final vehiclePowerState = VehicleSignal<VehiclePowerState>(
    key: 'vehicle.power.state',
    decode: VehiclePowerState.fromWireValue,
  );

  static final vehicleIgnitionState = VehicleSignal<VehicleIgnitionState>(
    key: 'vehicle.ignition.state',
    decode: VehicleIgnitionState.fromWireValue,
  );

  static final vehicleBatteryVoltage = VehicleSignal<double>(
    key: 'vehicle.battery.voltage',
    decode: _finiteDouble('vehicle.battery.voltage'),
  );

  static final audioVolumeUpPressed = _booleanSignal(
    'controls.audio.volume_up.pressed',
  );
  static final audioVolumeDownPressed = _booleanSignal(
    'controls.audio.volume_down.pressed',
  );
  static final audioMutePressed = _booleanSignal('controls.audio.mute.pressed');
  static final audioSourceNextPressed = _booleanSignal(
    'controls.audio.source_next.pressed',
  );
  static final audioSourcePreviousPressed = _booleanSignal(
    'controls.audio.source_previous.pressed',
  );

  static VehicleSignal<bool> _booleanSignal(String key) => VehicleSignal<bool>(
    key: key,
    decode: (value) {
      if (value is bool) return value;
      throw FormatException('$key must be a boolean.');
    },
  );

  static double Function(Object?) _finiteDouble(String key) => (value) {
    if (value is num) {
      final decoded = value.toDouble();
      if (decoded.isFinite) return decoded;
    }
    throw FormatException(
      '$key must be a finite integer or double, got ${value.runtimeType}.',
    );
  };
}
