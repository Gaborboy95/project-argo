/// Optional normalized ignition information for vehicles that expose it.
enum VehicleIgnitionState {
  unknown('unknown'),
  off('off'),
  accessory('accessory'),
  on('on'),
  start('start');

  const VehicleIgnitionState(this.wireValue);

  final String wireValue;

  static VehicleIgnitionState fromWireValue(Object? value) {
    if (value is String) {
      for (final state in values) {
        if (state.wireValue == value) return state;
      }
    }
    throw FormatException(
      'vehicle.ignition.state must be one of '
      '${values.map((state) => state.wireValue).join(', ')}, got "$value".',
    );
  }
}
