/// Host-side lifecycle for a vehicle transport whose consumers remain alive.
abstract interface class VehicleTransportLifecycle {
  Future<void> quiesce();

  Future<void> resume();
}

/// Used when there is no physical transport to stop or recreate.
final class NoOpVehicleTransportLifecycle implements VehicleTransportLifecycle {
  const NoOpVehicleTransportLifecycle();

  @override
  Future<void> quiesce() async {}

  @override
  Future<void> resume() async {}
}
