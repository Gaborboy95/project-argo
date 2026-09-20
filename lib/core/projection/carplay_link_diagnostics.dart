/// Read-only LIVI Link health. Reachability does not establish a CarPlay session.
enum CarPlayMfiHealth { unavailable, certificateOnly, ready }

final class CarPlayLinkHealth {
  const CarPlayLinkHealth({
    this.serviceAvailable = false,
    this.linkResolved = false,
    this.address,
    this.mfi = CarPlayMfiHealth.unavailable,
    this.protocolMajor,
    this.wifiControlAvailable = false,
    this.accessPointEnabled,
    this.bluetoothEnabled,
    this.error,
  });

  final bool serviceAvailable;
  final bool linkResolved;
  final String? address;
  final CarPlayMfiHealth mfi;
  final int? protocolMajor;
  final bool wifiControlAvailable;

  /// Reported radio state, independent of host transport availability.
  final bool? accessPointEnabled, bluetoothEnabled;
  final String? error;

  @override
  bool operator ==(Object other) =>
      other is CarPlayLinkHealth &&
      serviceAvailable == other.serviceAvailable &&
      linkResolved == other.linkResolved &&
      address == other.address &&
      mfi == other.mfi &&
      protocolMajor == other.protocolMajor &&
      wifiControlAvailable == other.wifiControlAvailable &&
      accessPointEnabled == other.accessPointEnabled &&
      bluetoothEnabled == other.bluetoothEnabled &&
      error == other.error;

  @override
  int get hashCode => Object.hash(
    serviceAvailable,
    linkResolved,
    address,
    mfi,
    protocolMajor,
    wifiControlAvailable,
    accessPointEnabled,
    bluetoothEnabled,
    error,
  );
}

abstract interface class CarPlayLinkDiagnostics {
  CarPlayLinkHealth get current;
  Stream<CarPlayLinkHealth> get changes;
  Future<void> refresh();
  Future<void> close();
}
