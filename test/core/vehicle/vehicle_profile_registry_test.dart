import 'package:argo/core/vehicle/vehicle_capability.dart';
import 'package:argo/core/vehicle/vehicle_profile.dart';
import 'package:argo/core/vehicle/vehicle_profile_registry.dart';
import 'package:argo/core/vehicle/vehicle_profiles.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('registers valid profiles in deterministic order', () {
    final registry = VehicleProfileRegistry()
      ..register(_profile('generic'))
      ..register(_profile('development'));

    expect(
      registry.profiles.map((profile) => profile.id),
      orderedEquals(['generic', 'development']),
    );
    expect(
      () => registry.profiles.add(_profile('another')),
      throwsUnsupportedError,
    );
  });

  test('rejects invalid profile IDs', () {
    for (final id in ['', 'Generic', 'generic profile', '.generic']) {
      expect(
        () => _profile(id),
        throwsA(
          isA<ArgumentError>().having((error) => error.name, 'name', 'id'),
        ),
      );
    }
  });

  test('rejects duplicate profile IDs', () {
    final registry = VehicleProfileRegistry()..register(_profile('generic'));

    expect(
      () => registry.register(_profile('generic')),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('Vehicle profile "generic" is already registered'),
        ),
      ),
    );
  });

  test('looks up profiles and reports missing profiles clearly', () {
    final profile = _profile('generic');
    final registry = VehicleProfileRegistry()..register(profile);

    expect(registry.contains('generic'), isTrue);
    expect(registry.get('generic'), same(profile));
    expect(
      () => registry.get('missing'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('Required vehicle profile "missing" is not registered'),
        ),
      ),
    );
  });

  test('profile capabilities are declared and immutable', () {
    final mutableCapabilities = <VehicleCapability>{
      VehicleCapabilities.telemetry,
    };
    final profile = VehicleProfile(
      id: 'connected',
      displayName: 'Connected vehicle',
      capabilities: mutableCapabilities,
    );
    mutableCapabilities.add(VehicleCapabilities.climateControl);

    expect(profile.capabilities, {VehicleCapabilities.telemetry});
    expect(
      () => profile.capabilities.add(VehicleCapabilities.parkingSensors),
      throwsUnsupportedError,
    );
  });

  test('built-in generic profile is conservative', () {
    final registry = VehicleProfileRegistry();

    registerBuiltInVehicleProfiles(registry);

    expect(registry.profiles, hasLength(1));
    final generic = registry.get(VehicleProfiles.genericId);
    expect(generic.displayName, 'Generic vehicle');
    expect(generic.capabilities, isEmpty);
  });
}

VehicleProfile _profile(String id) =>
    VehicleProfile(id: id, displayName: id.isEmpty ? 'Invalid' : id);
