import '../vehicle/vehicle_ignition_state.dart';
import '../vehicle/vehicle_power_state.dart';
import 'head_unit_operational_state.dart';

/// The latest independently observed normalized vehicle power information.
final class HeadUnitPowerSnapshot {
  const HeadUnitPowerSnapshot({
    this.vehiclePowerState = VehiclePowerState.unknown,
    this.ignitionState,
    this.batteryVoltage,
    this.updatedAt,
  });

  final VehiclePowerState vehiclePowerState;
  final VehicleIgnitionState? ignitionState;
  final double? batteryVoltage;
  final DateTime? updatedAt;

  HeadUnitOperationalState get operationalState =>
      HeadUnitOperationalState.fromVehiclePowerState(vehiclePowerState);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HeadUnitPowerSnapshot &&
          other.vehiclePowerState == vehiclePowerState &&
          other.ignitionState == ignitionState &&
          other.batteryVoltage == batteryVoltage &&
          other.updatedAt == updatedAt;

  @override
  int get hashCode =>
      Object.hash(vehiclePowerState, ignitionState, batteryVoltage, updatedAt);
}
