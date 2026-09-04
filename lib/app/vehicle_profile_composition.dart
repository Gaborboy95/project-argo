import 'dart:io';

import '../core/services/service_registry.dart';
import '../core/vehicle/integration/vehicle_integration_bundle.dart';
import '../core/vehicle/integration/vehicle_integration_discovery.dart';
import '../core/vehicle/vehicle_capability_service.dart';
import '../core/vehicle/vehicle_profile.dart';
import '../core/vehicle/vehicle_profile_registry.dart';
import '../core/vehicle/vehicle_profile_selection.dart';

/// Selects and registers the application-facing vehicle identity services.
VehicleProfile registerVehicleProfileServices({
  required ServiceRegistry services,
  required VehicleProfileRegistry profiles,
  required Map<String, String> environment,
  Iterable<VehicleIntegrationBundle> externalIntegrations = const [],
  Iterable<VehicleIntegrationDiscoveryFailure> discoveryFailures = const [],
}) {
  for (final integration in externalIntegrations) {
    try {
      profiles.register(integration.profile);
    } on StateError catch (error) {
      throw StateError(
        'External vehicle integration "${integration.rootDirectory.path}" '
        'cannot register profile "${integration.profile.id}": '
        '${error.message}',
      );
    }
  }

  final configuredId = environment['ARGO_VEHICLE_PROFILE']?.trim();
  if (configuredId != null && configuredId.isNotEmpty) {
    for (final failure in discoveryFailures) {
      if (failure.profileId == configuredId ||
          _directoryName(failure.bundleDirectory) == configuredId) {
        Error.throwWithStackTrace(failure.error, failure.stackTrace);
      }
    }
  }

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

String _directoryName(Directory directory) {
  final segments = directory.uri.pathSegments.where(
    (segment) => segment.isNotEmpty,
  );
  return segments.isEmpty ? directory.path : segments.last;
}
