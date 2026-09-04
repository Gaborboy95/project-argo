import 'package:argo/core/vehicle/vehicle_ignition_state.dart';
import 'package:argo/core/vehicle/vehicle_power_state.dart';
import 'package:argo/core/vehicle/vehicle_signals.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('audio control signals accept only booleans', () {
    expect(VehicleSignals.audioVolumeUpPressed.decode(true), isTrue);
    expect(
      () => VehicleSignals.audioVolumeUpPressed.decode(1),
      throwsFormatException,
    );
  });
  test('engine RPM normalizes integers and doubles', () {
    expect(VehicleSignals.engineRpm.decode(3000), 3000.0);
    expect(VehicleSignals.engineRpm.decode(2875.5), 2875.5);
  });

  test('engine RPM rejects non-numeric values', () {
    expect(
      () => VehicleSignals.engineRpm.decode('3000'),
      throwsFormatException,
    );
  });

  test('decodes every normalized vehicle power state', () {
    for (final state in VehiclePowerState.values) {
      expect(VehicleSignals.vehiclePowerState.decode(state.wireValue), state);
    }
  });

  test('rejects invalid vehicle power state values', () {
    for (final value in <Object?>['running', 'AWAKE', 1, null]) {
      expect(
        () => VehicleSignals.vehiclePowerState.decode(value),
        throwsFormatException,
      );
    }
  });

  test('decodes every normalized ignition state', () {
    for (final state in VehicleIgnitionState.values) {
      expect(
        VehicleSignals.vehicleIgnitionState.decode(state.wireValue),
        state,
      );
    }
  });

  test('rejects invalid ignition state values', () {
    for (final value in <Object?>['running', 'OFF', 0, null]) {
      expect(
        () => VehicleSignals.vehicleIgnitionState.decode(value),
        throwsFormatException,
      );
    }
  });

  test('battery voltage normalizes finite integers and doubles', () {
    expect(VehicleSignals.vehicleBatteryVoltage.decode(12), 12.0);
    expect(VehicleSignals.vehicleBatteryVoltage.decode(12.6), 12.6);
    for (final value in <Object?>['12.6', double.nan, double.infinity, null]) {
      expect(
        () => VehicleSignals.vehicleBatteryVoltage.decode(value),
        throwsFormatException,
      );
    }
  });
}
