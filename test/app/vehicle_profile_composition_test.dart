import 'dart:io';

import 'package:argo/app/vehicle_profile_composition.dart';
import 'package:argo/core/services/service_registry.dart';
import 'package:argo/core/vehicle/integration/vehicle_integration_bundle.dart';
import 'package:argo/core/vehicle/integration/vehicle_integration_discovery.dart';
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

  test('registers and selects an external integration profile', () {
    final profiles = VehicleProfileRegistry();
    registerBuiltInVehicleProfiles(profiles);
    final externalProfile = VehicleProfile(
      id: 'example-vehicle',
      displayName: 'Example Vehicle',
      capabilities: {VehicleCapabilities.telemetry},
    );
    final integrationRoot = Directory('/test/example-vehicle');
    final integration = VehicleIntegrationBundle(
      profile: externalProfile,
      rootDirectory: integrationRoot,
      velocePluginDirectory: Directory.fromUri(
        integrationRoot.uri.resolve('plugins/'),
      ),
    );
    final services = ServiceRegistry();

    final selected = registerVehicleProfileServices(
      services: services,
      profiles: profiles,
      environment: const {'ARGO_VEHICLE_PROFILE': 'example-vehicle'},
      externalIntegrations: [integration],
    );

    expect(selected, same(externalProfile));
    expect(
      services.get<VehicleCapabilityService>().supports(
        VehicleCapabilities.telemetry,
      ),
      isTrue,
    );
  });

  test('rejects an external profile colliding with built-in generic', () {
    final profiles = VehicleProfileRegistry();
    registerBuiltInVehicleProfiles(profiles);
    final integrationRoot = Directory('/test/generic');
    final integration = VehicleIntegrationBundle(
      profile: VehicleProfile(
        id: VehicleProfiles.genericId,
        displayName: 'External Generic',
      ),
      rootDirectory: integrationRoot,
      velocePluginDirectory: Directory.fromUri(
        integrationRoot.uri.resolve('plugins/'),
      ),
    );

    expect(
      () => registerVehicleProfileServices(
        services: ServiceRegistry(),
        profiles: profiles,
        environment: const {},
        externalIntegrations: [integration],
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          allOf(
            contains('External vehicle integration'),
            contains('Vehicle profile "generic" is already registered'),
          ),
        ),
      ),
    );
  });

  test('a malformed selected integration retains its discovery error', () {
    final profiles = VehicleProfileRegistry();
    registerBuiltInVehicleProfiles(profiles);
    final error = FormatException('Selected manifest is invalid.');
    final failure = VehicleIntegrationDiscoveryFailure(
      bundleDirectory: Directory('/test/example-vehicle'),
      profileId: 'example-vehicle',
      error: error,
      stackTrace: StackTrace.current,
    );

    expect(
      () => registerVehicleProfileServices(
        services: ServiceRegistry(),
        profiles: profiles,
        environment: const {'ARGO_VEHICLE_PROFILE': 'example-vehicle'},
        discoveryFailures: [failure],
      ),
      throwsA(same(error)),
    );
  });
}
