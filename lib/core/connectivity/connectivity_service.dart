/// Shared device/network contract. No radio secrets enter this model.
abstract interface class ConnectivityService {
  ConnectivitySnapshot get connectivity;
  Stream<ConnectivitySnapshot> get connectivityChanges;
  Future<void> connectivityCommand(
    String action, {
    String target = '',
    bool accept = false,
    int prompt = 0,
  });
}

final class ConnectivityRadio {
  const ConnectivityRadio(
    this.id,
    this.name, {
    this.address,
    this.usable,
    this.detail,
  });
  final String? address;
  final bool? usable;
  final String? detail;
  final String id, name;
}

final class ConnectivityDevice {
  const ConnectivityDevice(this.id, this.name, this.paired, this.connected);
  final String id, name;
  final bool paired, connected;
}

final class PairingPrompt {
  const PairingPrompt(this.id, this.device, this.name, this.text);
  final int id;
  final String device, name, text;
}

final class ConnectivitySnapshot {
  const ConnectivitySnapshot({
    this.available = false,
    this.adapters = const [],
    this.networks = const [],
    this.devices = const [],
    this.adapter = '',
    this.interface = '',
    this.selected = '',
    this.enabled = false,
    this.discovering = false,
    this.wifiConnected = false,
    this.phase = 'unavailable',
    this.detail = 'Connectivity daemon unavailable',
    this.cleanupError = '',
    this.prompt,
    this.band,
    this.apFrequencyMhz,
    this.music,
    this.wirelessAvailable,
  });
  final bool? wirelessAvailable;
  final bool available, enabled, discovering, wifiConnected;
  final List<ConnectivityRadio> adapters, networks;
  final List<ConnectivityDevice> devices;
  final String adapter, interface, selected, phase, detail;
  final String cleanupError;
  final PairingPrompt? prompt;

  /// Null means the daemon predates selectable AP bands.
  final String? band;
  final int? apFrequencyMhz;
  final Map<String, dynamic>? music;
  factory ConnectivitySnapshot.fromJson(Map<String, dynamic> j) {
    List<ConnectivityRadio> radios(String key) => (j[key] as List)
        .map(
          (r) => ConnectivityRadio(
            r['id'] as String,
            r['name'] as String,
            address: r['address'] as String?,
            usable: r['usable'] as bool?,
            detail: r['detail'] as String?,
          ),
        )
        .toList(growable: false);
    final p = j['prompt'];
    return ConnectivitySnapshot(
      music: j['music'] as Map<String, dynamic>?,
      wirelessAvailable: j['wireless_available'] as bool?,
      available: j['phase'] != 'unavailable',
      adapters: radios('adapters'),
      networks: radios('networks'),
      devices: (j['devices'] as List)
          .map(
            (d) => ConnectivityDevice(
              d['id'] as String,
              d['name'] as String,
              d['paired'] as bool,
              d['connected'] as bool,
            ),
          )
          .toList(growable: false),
      adapter: j['adapter'] as String,
      interface: j['interface'] as String,
      selected: j['selected'] as String,
      enabled: j['enabled'] as bool,
      discovering: j['discovering'] as bool,
      wifiConnected: j['wifi_connected'] as bool,
      phase: j['phase'] as String,
      detail: j['detail'] as String,
      cleanupError: j['cleanup_error'] as String? ?? '',
      band: j['band'] as String?,
      apFrequencyMhz: j['ap_frequency_mhz'] as int?,
      prompt: p == null
          ? null
          : PairingPrompt(
              p['id'] as int,
              p['device'] as String,
              p['name'] as String,
              p['text'] as String,
            ),
    );
  }
}
