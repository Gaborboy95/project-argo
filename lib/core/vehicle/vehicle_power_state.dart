/// Normalized vehicle-level power semantics supplied by a vehicle integration.
enum VehiclePowerState {
  /// No trustworthy vehicle power information is currently available.
  unknown('unknown'),

  /// The vehicle or in-vehicle network is in its low-power state.
  asleep('asleep'),

  /// The vehicle is awake without necessarily requiring indefinite activity.
  awake('awake'),

  /// The vehicle requests that the head unit remain fully operational.
  active('active');

  const VehiclePowerState(this.wireValue);

  final String wireValue;

  static VehiclePowerState fromWireValue(Object? value) {
    if (value is String) {
      for (final state in values) {
        if (state.wireValue == value) return state;
      }
    }
    throw FormatException(
      'vehicle.power.state must be one of '
      '${values.map((state) => state.wireValue).join(', ')}, got "$value".',
    );
  }
}
