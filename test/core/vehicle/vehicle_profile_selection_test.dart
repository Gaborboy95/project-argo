import 'package:argo/core/vehicle/vehicle_profile.dart';
import 'package:argo/core/vehicle/vehicle_profile_registry.dart';
import 'package:argo/core/vehicle/vehicle_profile_selection.dart';
import 'package:argo/core/vehicle/vehicle_profiles.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late VehicleProfile generic;
  late VehicleProfile development;
  late VehicleProfileRegistry profiles;

  setUp(() {
    generic = VehicleProfile(
      id: VehicleProfiles.genericId,
      displayName: 'Generic vehicle',
    );
    development = VehicleProfile(
      id: 'development',
      displayName: 'Development vehicle',
    );
    profiles = VehicleProfileRegistry()
      ..register(generic)
      ..register(development);
  });

  test('defaults to the generic profile', () {
    expect(
      selectVehicleProfile(environment: const {}, profiles: profiles),
      same(generic),
    );
  });

  test('selects an explicitly configured profile', () {
    expect(
      selectVehicleProfile(
        environment: const {'ARGO_VEHICLE_PROFILE': ' development '},
        profiles: profiles,
      ),
      same(development),
    );
  });

  test('rejects unknown or empty explicit profiles', () {
    for (final id in ['', 'unknown', 'Generic']) {
      expect(
        () => selectVehicleProfile(
          environment: {'ARGO_VEHICLE_PROFILE': id},
          profiles: profiles,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.name,
            'name',
            'ARGO_VEHICLE_PROFILE',
          ),
        ),
      );
    }
  });
}
