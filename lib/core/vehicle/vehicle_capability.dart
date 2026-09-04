/// A stable application-facing capability that a vehicle profile can declare.
final class VehicleCapability {
  factory VehicleCapability({required String id}) {
    if (id.length > 128 || !_idPattern.hasMatch(id)) {
      throw ArgumentError.value(
        id,
        'id',
        'Must be a stable namespaced capability identifier',
      );
    }
    return VehicleCapability._(id);
  }

  const VehicleCapability._(this.id);

  static final RegExp _idPattern = RegExp(
    r'^[a-z][A-Za-z0-9_-]*(?:\.[a-z][A-Za-z0-9_-]*)+$',
  );

  final String id;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is VehicleCapability && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'VehicleCapability($id)';
}

/// The deliberately small catalog of capabilities currently understood by
/// Argo. Profiles may declare only the capabilities they officially support.
abstract final class VehicleCapabilities {
  static final telemetry = VehicleCapability(id: 'vehicle.telemetry');
  static final climateControl = VehicleCapability(id: 'climate.control');
  static final parkingSensors = VehicleCapability(id: 'parking.sensors');
  static final reverseCamera = VehicleCapability(id: 'camera.reverse');
}
