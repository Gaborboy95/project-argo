import 'vehicle_capability.dart';
import 'vehicle_profile.dart';

/// Application-facing access to the active profile's declared capabilities.
abstract interface class VehicleCapabilityService {
  bool supports(VehicleCapability capability);

  Set<VehicleCapability> get supported;
}

/// Capability service backed solely by an immutable active profile.
final class ProfileVehicleCapabilityService
    implements VehicleCapabilityService {
  const ProfileVehicleCapabilityService(this.profile);

  final VehicleProfile profile;

  @override
  Set<VehicleCapability> get supported => profile.capabilities;

  @override
  bool supports(VehicleCapability capability) =>
      profile.capabilities.contains(capability);
}
