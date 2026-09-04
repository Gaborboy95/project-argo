import 'package:argo/core/vehicle/vehicle_capability.dart';
import 'package:argo/core/vehicle/vehicle_capability_service.dart';
import 'package:argo/core/vehicle/vehicle_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('queries profile-declared supported and unsupported capabilities', () {
    final profile = VehicleProfile(
      id: 'connected',
      displayName: 'Connected vehicle',
      capabilities: {
        VehicleCapabilities.telemetry,
        VehicleCapabilities.parkingSensors,
      },
    );
    final service = ProfileVehicleCapabilityService(profile);

    expect(service.supported, profile.capabilities);
    expect(service.supports(VehicleCapabilities.telemetry), isTrue);
    expect(
      service.supports(VehicleCapability(id: 'vehicle.telemetry')),
      isTrue,
    );
    expect(service.supports(VehicleCapabilities.climateControl), isFalse);
  });

  test('generic profile can conservatively declare no capabilities', () {
    final profile = VehicleProfile(
      id: 'generic',
      displayName: 'Generic vehicle',
    );
    final service = ProfileVehicleCapabilityService(profile);

    expect(service.supported, isEmpty);
    expect(service.supports(VehicleCapabilities.telemetry), isFalse);
  });
}
