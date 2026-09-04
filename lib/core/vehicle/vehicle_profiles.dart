import 'vehicle_profile.dart';
import 'vehicle_profile_registry.dart';

abstract final class VehicleProfiles {
  static const genericId = 'generic';
}

/// Registers the profiles supplied by Argo itself in deterministic order.
void registerBuiltInVehicleProfiles(VehicleProfileRegistry registry) {
  registry.register(
    VehicleProfile(
      id: VehicleProfiles.genericId,
      displayName: 'Generic vehicle',
    ),
  );
}
