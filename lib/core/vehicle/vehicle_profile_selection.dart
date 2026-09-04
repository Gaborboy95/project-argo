import 'vehicle_profile.dart';
import 'vehicle_profile_registry.dart';
import 'vehicle_profiles.dart';

/// Resolves the one active vehicle profile selected for this application run.
VehicleProfile selectVehicleProfile({
  required Map<String, String> environment,
  required VehicleProfileRegistry profiles,
}) {
  final configured = environment['ARGO_VEHICLE_PROFILE'];
  if (configured == null) return profiles.get(VehicleProfiles.genericId);

  final id = configured.trim();
  if (id.isEmpty || !profiles.contains(id)) {
    throw ArgumentError.value(
      configured,
      'ARGO_VEHICLE_PROFILE',
      'Unknown vehicle profile "$id"',
    );
  }
  return profiles.get(id);
}
