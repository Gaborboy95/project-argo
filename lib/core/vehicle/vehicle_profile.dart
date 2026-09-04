import 'vehicle_capability.dart';

/// Immutable identity and declared application capabilities for a vehicle
/// integration.
final class VehicleProfile {
  factory VehicleProfile({
    required String id,
    required String displayName,
    Set<VehicleCapability> capabilities = const {},
  }) {
    if (id.length > 128 || !_idPattern.hasMatch(id)) {
      throw ArgumentError.value(
        id,
        'id',
        'Must be a stable lowercase profile identifier',
      );
    }
    if (displayName.trim().isEmpty) {
      throw ArgumentError.value(
        displayName,
        'displayName',
        'Must not be empty',
      );
    }
    return VehicleProfile._(
      id: id,
      displayName: displayName,
      capabilities: Set.unmodifiable(capabilities),
    );
  }

  const VehicleProfile._({
    required this.id,
    required this.displayName,
    required this.capabilities,
  });

  static final RegExp _idPattern = RegExp(
    r'^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$',
  );

  final String id;
  final String displayName;
  final Set<VehicleCapability> capabilities;
}
