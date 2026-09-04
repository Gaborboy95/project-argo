import 'vehicle_profile.dart';

/// An explicitly populated, deterministically ordered vehicle profile catalog.
final class VehicleProfileRegistry {
  final List<VehicleProfile> _profiles = [];
  final Map<String, VehicleProfile> _profilesById = {};

  List<VehicleProfile> get profiles => List.unmodifiable(_profiles);

  void register(VehicleProfile profile) {
    if (_profilesById.containsKey(profile.id)) {
      throw StateError(
        'Vehicle profile "${profile.id}" is already registered.',
      );
    }
    _profiles.add(profile);
    _profilesById[profile.id] = profile;
  }

  bool contains(String id) => _profilesById.containsKey(id);

  VehicleProfile get(String id) {
    final profile = _profilesById[id];
    if (profile == null) {
      throw StateError('Required vehicle profile "$id" is not registered.');
    }
    return profile;
  }
}
