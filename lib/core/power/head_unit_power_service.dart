import 'head_unit_power_snapshot.dart';

/// Application-facing normalized vehicle/head-unit power state.
abstract interface class HeadUnitPowerService {
  HeadUnitPowerSnapshot get current;

  Stream<HeadUnitPowerSnapshot> get changes;

  Future<void> close();
}
