import '../projection/projection_types.dart';

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
  const ConnectivityDevice(
    this.id,
    this.name,
    this.paired,
    this.connected, {
    this.protocols = const {},
    this.audioSource = false,
  });
  final String id, name;
  final bool paired, connected;
  final bool audioSource;
  final Set<ProjectionProtocol> protocols;
  String get adapterId =>
      id.contains('/') ? id.substring(0, id.indexOf('/')) : '';
  String? get address => bluetoothAddress(id.split('/').last);
}

/// BlueZ object references remain command targets. A phone's Bluetooth address
/// is its inventory identity across controller enumeration and alias changes.
String? bluetoothAddress(String value) {
  final address = value
      .trim()
      .replaceAll('_', ':')
      .replaceAll('-', ':')
      .toUpperCase();
  return RegExp(r'^(?:[0-9A-F]{2}:){5}[0-9A-F]{2}$').hasMatch(address)
      ? address
      : null;
}

final class ConnectivityDeviceGroup {
  ConnectivityDeviceGroup(this.id, List<ConnectivityDevice> endpoints)
    : endpoints = List.unmodifiable(endpoints);
  final String id;
  final List<ConnectivityDevice> endpoints;
  String get name => _deviceName(
    endpoints.map((d) => d.name),
    endpoints.first.address ?? endpoints.first.id,
  );
  String get identifier => endpoints.first.address ?? endpoints.first.id;
  bool get paired => endpoints.any((d) => d.paired);
  bool get connected => endpoints.any((d) => d.connected);
  bool get audioSource => endpoints.any((d) => d.audioSource);
  Set<ProjectionProtocol> get protocols => Set.unmodifiable({
    for (final endpoint in endpoints) ...endpoint.protocols,
  });
  ConnectivityDevice? forAdapter(String adapter) => endpoints
      .where((d) => adapter.isNotEmpty && d.adapterId == adapter)
      .firstOrNull;
}

String connectivityDeviceReference(String reference) {
  final separator = reference.indexOf('/');
  if (separator < 0) return reference;
  final address = bluetoothAddress(reference.substring(separator + 1));
  return address == null
      ? reference
      : '${reference.substring(0, separator)}/$address';
}

String _deviceName(Iterable<String> names, String fallback) {
  final candidates = names
      .map((name) => name.trim())
      .where((name) => name.isNotEmpty)
      .toSet()
      .toList();
  candidates.sort((a, b) {
    final aAddress = bluetoothAddress(a) != null || a == fallback;
    final bAddress = bluetoothAddress(b) != null || b == fallback;
    if (aAddress != bAddress) return aAddress ? 1 : -1;
    final comparison = a.toLowerCase().compareTo(b.toLowerCase());
    return comparison == 0 ? a.compareTo(b) : comparison;
  });
  return candidates.firstOrNull ?? fallback;
}

List<ConnectivityRadio> _radios(Iterable<ConnectivityRadio> radios) {
  final byId = <String, ConnectivityRadio>{};
  for (final radio in radios) {
    final previous = byId[radio.id];
    byId[radio.id] = ConnectivityRadio(
      radio.id,
      _deviceName([if (previous != null) previous.name, radio.name], radio.id),
      address: radio.address ?? previous?.address,
      usable: radio.usable ?? previous?.usable,
      detail: radio.detail ?? previous?.detail,
    );
  }
  final result = byId.values.toList()
    ..sort(
      (a, b) => (bluetoothAddress(a.address ?? '') ?? a.id).compareTo(
        bluetoothAddress(b.address ?? '') ?? b.id,
      ),
    );
  return List.unmodifiable(result);
}

List<ConnectivityDevice> _devices(
  Iterable<ConnectivityDevice> devices,
  List<ConnectivityRadio> adapters,
) {
  final byId = <String, ConnectivityDevice>{};
  for (final device in devices) {
    final address = device.address;
    final id = connectivityDeviceReference(device.id);
    final previous = byId[id];
    byId[id] = ConnectivityDevice(
      id,
      _deviceName([
        if (previous != null) previous.name,
        device.name,
      ], address ?? id),
      device.paired || previous?.paired == true,
      device.connected || previous?.connected == true,
      audioSource: device.audioSource || previous?.audioSource == true,
      protocols: Set.unmodifiable({
        if (previous != null) ...previous.protocols,
        ...device.protocols,
      }),
    );
  }
  String key(ConnectivityDevice device) {
    final adapter = adapters.where((r) => r.id == device.adapterId).firstOrNull;
    return '${bluetoothAddress(adapter?.address ?? '') ?? device.adapterId}/${device.address ?? device.id}';
  }

  final result = byId.values.toList()..sort((a, b) => key(a).compareTo(key(b)));
  return List.unmodifiable(result);
}

final class PairingPrompt {
  const PairingPrompt(this.id, this.device, this.name, this.text);
  final int id;
  final String device, name, text;
}

final class ConnectivitySnapshot {
  const ConnectivitySnapshot({
    this.available = false,
    this.daemonConnected = false,
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
    this.calls,
    this.voice,
    this.stopped,
    this.wirelessAvailable,
  });
  final bool daemonConnected;
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
  final Map<String, dynamic>? music, calls, voice;
  final int? stopped;

  /// All protocols share this address-based inventory. Do not merge by name:
  /// different phones can legitimately use the same alias.
  List<ConnectivityDeviceGroup> get deviceGroups {
    final grouped = <String, List<ConnectivityDevice>>{};
    for (final device in _devices(devices, adapters)) {
      final identity = device.address == null
          ? 'device:${device.id}'
          : 'bluetooth:${device.address}';
      grouped.putIfAbsent(identity, () => []).add(device);
    }
    final ids = grouped.keys.toList()..sort();
    return List.unmodifiable([
      for (final id in ids) ConnectivityDeviceGroup(id, grouped[id]!),
    ]);
  }

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
    final adapters = _radios(radios('adapters'));
    Map<String, dynamic>? state(String key) {
      final value = j[key] as Map<String, dynamic>?;
      if (value == null) return null;
      return {
        ...value,
        if (value['device'] is String)
          'device': connectivityDeviceReference(value['device'] as String),
      };
    }

    return ConnectivitySnapshot(
      daemonConnected: true,
      music: state('music'),
      calls: state('calls'),
      voice: state('voice'),
      stopped: j['stopped'] as int?,
      wirelessAvailable: j['wireless_available'] as bool?,
      available: j['phase'] != 'unavailable',
      adapters: adapters,
      networks: _radios(radios('networks')),
      devices: _devices(
        (j['devices'] as List)
            .map(
              (d) => ConnectivityDevice(
                d['id'] as String,
                d['name'] as String,
                d['paired'] as bool,
                d['connected'] as bool,
                audioSource: d['audio_source'] == true,
                protocols: Set.unmodifiable({
                  for (final protocol in d['protocols'] as List? ?? const [])
                    if (protocol == 'android-auto')
                      ProjectionProtocol.androidAuto
                    else if (protocol == 'carplay')
                      ProjectionProtocol.carPlay,
                }),
              ),
            )
            .toList(growable: false),
        adapters,
      ),
      adapter: j['adapter'] as String,
      interface: j['interface'] as String,
      selected: connectivityDeviceReference(j['selected'] as String),
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
              connectivityDeviceReference(p['device'] as String),
              p['name'] as String,
              p['text'] as String,
            ),
    );
  }
}
