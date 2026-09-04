import 'package:argo/app/vehicle_profile_composition.dart';
import 'package:argo/core/services/service_registry.dart';
import 'package:argo/core/vehicle/vehicle_capability.dart';
import 'package:argo/core/vehicle/vehicle_capability_service.dart';
import 'package:argo/core/vehicle/vehicle_profile.dart';
import 'package:argo/core/vehicle/vehicle_profile_registry.dart';
import 'package:argo/core/vehicle/vehicle_profiles.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('registers the default built-in profile during composition', () {
    final profiles = VehicleProfileRegistry();
    registerBuiltInVehicleProfiles(profiles);
    final services = ServiceRegistry();

    registerVehicleProfileServices(
      services: services,
      profiles: profiles,
      environment: const {},
    );

    expect(services.get<VehicleProfile>().id, VehicleProfiles.genericId);
    expect(services.get<VehicleCapabilityService>().supported, isEmpty);
  });

  test('registers the selected profile and capability service', () {
    final generic = VehicleProfile(
      id: 'generic',
      displayName: 'Generic vehicle',
    );
    final connected = VehicleProfile(
      id: 'connected',
      displayName: 'Connected vehicle',
      capabilities: {VehicleCapabilities.telemetry},
    );
    final profiles = VehicleProfileRegistry()
      ..register(generic)
      ..register(connected);
    final services = ServiceRegistry();

    final selected = registerVehicleProfileServices(
      services: services,
      profiles: profiles,
      environment: const {'ARGO_VEHICLE_PROFILE': 'connected'},
    );

    expect(selected, same(connected));
    expect(services.get<VehicleProfile>(), same(connected));
    expect(
      services.get<VehicleCapabilityService>().supports(
        VehicleCapabilities.telemetry,
      ),
      isTrue,
    );
  });
}
