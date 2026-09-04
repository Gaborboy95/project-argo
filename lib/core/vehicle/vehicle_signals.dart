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
