import '../vehicle/vehicle_power_state.dart';

/// Argo's current operational eligibility; it does not invoke host power APIs.
enum HeadUnitOperationalState {
  /// Argo cannot yet determine operational eligibility.
  unknown('unknown'),

  /// Argo considers the head unit eligible for standby; no OS action occurs.
  standby('standby'),

  /// Argo considers the head unit operationally awake.
  awake('awake');

  const HeadUnitOperationalState(this.wireValue);

  final String wireValue;

  static HeadUnitOperationalState fromVehiclePowerState(
    VehiclePowerState state,
  ) => switch (state) {
    VehiclePowerState.unknown => HeadUnitOperationalState.unknown,
    VehiclePowerState.asleep => HeadUnitOperationalState.standby,
    VehiclePowerState.awake ||
    VehiclePowerState.active => HeadUnitOperationalState.awake,
  };
}
