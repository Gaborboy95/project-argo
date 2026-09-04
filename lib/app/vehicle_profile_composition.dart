import '../core/services/service_registry.dart';
import '../core/vehicle/vehicle_capability_service.dart';
import '../core/vehicle/vehicle_profile.dart';
import '../core/vehicle/vehicle_profile_registry.dart';
import '../core/vehicle/vehicle_profile_selection.dart';

/// Selects and registers the application-facing vehicle identity services.
VehicleProfile registerVehicleProfileServices({
  required ServiceRegistry services,
  required VehicleProfileRegistry profiles,
  required Map<String, String> environment,
}) {
  final activeProfile = selectVehicleProfile(
    environment: environment,
    profiles: profiles,
  );
  services
    ..register<VehicleProfile>(activeProfile)
    ..register<VehicleCapabilityService>(
      ProfileVehicleCapabilityService(activeProfile),
    );
  return activeProfile;
}
