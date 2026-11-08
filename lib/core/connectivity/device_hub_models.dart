import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../projection/projection_models.dart';
import '../projection/projection_types.dart';
import 'connectivity_service.dart';

String deviceProtocolLabel(ProjectionProtocol protocol) => switch (protocol) {
  ProjectionProtocol.androidAuto => 'Android Auto',
  ProjectionProtocol.carPlay => 'CarPlay',
};

String deviceProtocolValue(ProjectionProtocol protocol) => switch (protocol) {
  ProjectionProtocol.androidAuto => 'android-auto',
  ProjectionProtocol.carPlay => 'carplay',
};

ProjectionProtocol? deviceProtocolFromValue(Object? value) => switch (value) {
  'android-auto' || 'androidAuto' => ProjectionProtocol.androidAuto,
  'carplay' || 'carPlay' => ProjectionProtocol.carPlay,
  _ => null,
};

/// A remembered physical phone, not a transport or an active connection.
/// Projection bindings are saved only after the application confirms identity.
final class RememberedPhone {
  RememberedPhone({
    required this.id,
    required this.name,
    String? address,
    this.protocol,
    this.bluetoothOnly = false,
    Map<ProjectionProtocol, Set<String>> projectionIds = const {},
  }) : address = address == null ? null : bluetoothAddress(address),
       projectionIds = Map.unmodifiable({
         for (final entry in projectionIds.entries)
           entry.key: Set<String>.unmodifiable(entry.value),
       });

  final String id, name;
  final String? address;
  final ProjectionProtocol? protocol;
  final bool bluetoothOnly;
  final Map<ProjectionProtocol, Set<String>> projectionIds;

  RememberedPhone copyWith({
    String? name,
    String? address,
    ProjectionProtocol? protocol,
    bool? bluetoothOnly,
    Map<ProjectionProtocol, Set<String>>? projectionIds,
  }) => RememberedPhone(
    id: id,
    name: name ?? this.name,
    address: address ?? this.address,
    protocol: protocol ?? this.protocol,
    bluetoothOnly: bluetoothOnly ?? this.bluetoothOnly,
    projectionIds: projectionIds ?? this.projectionIds,
  );

  factory RememberedPhone.fromJson(Map<String, dynamic> json) {
    String text(Object? value, String field, {int limit = 1024}) {
      if (value is! String ||
          value.isEmpty ||
          value.length > limit ||
          value.contains(RegExp(r'[\x00-\x1f]'))) {
        throw FormatException('Invalid remembered phone $field');
      }
      return value;
    }

    final id = text(json['id'], 'id');
    final name = text(json['name'], 'name', limit: 256);
    final address = json['address'];
    if (address != null &&
        (address is! String || bluetoothAddress(address) == null)) {
      throw const FormatException('Invalid remembered phone address');
    }
    final protocol = deviceProtocolFromValue(json['protocol']);
    if (json['protocol'] != null && protocol == null) {
      throw const FormatException('Invalid remembered phone protocol');
    }
    if (json['bluetooth_only'] != null && json['bluetooth_only'] is! bool) {
      throw const FormatException('Invalid remembered Bluetooth preference');
    }
    final bindings = json['projection_ids'];
    if (bindings != null && bindings is! Map) {
      throw const FormatException('Invalid remembered phone bindings');
    }
    final projectionIds = <ProjectionProtocol, Set<String>>{};
    if (bindings is Map) {
      if (bindings.length > ProjectionProtocol.values.length) {
        throw const FormatException('Too many remembered phone protocols');
      }
      for (final entry in bindings.entries) {
        final protocol = deviceProtocolFromValue(entry.key);
        final values = entry.value;
        if (protocol == null || values is! List || values.length > 32) {
          throw const FormatException('Invalid remembered phone bindings');
        }
        projectionIds[protocol] = {
          for (final value in values) text(value, 'projection id'),
        };
      }
    }
    return RememberedPhone(
      id: id,
      name: name,
      address: address as String?,
      protocol: protocol,
      bluetoothOnly: json['bluetooth_only'] == true,
      projectionIds: projectionIds,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    if (address != null) 'address': address,
    if (protocol != null) 'protocol': deviceProtocolValue(protocol!),
    if (bluetoothOnly) 'bluetooth_only': true,
    if (projectionIds.isNotEmpty)
      'projection_ids': {
        for (final entry in projectionIds.entries)
          deviceProtocolValue(entry.key): entry.value.toList()..sort(),
      },
  };
}

/// One physical phone with independently addressed Bluetooth/projection routes.
final class DeviceHubDevice {
  DeviceHubDevice({
    required this.id,
    required this.name,
    required this.identifier,
    required Iterable<ConnectivityDevice> endpoints,
    required Iterable<ProjectionSession> sessions,
    required Iterable<ProjectionProtocol> protocols,
    required this.protocol,
    required this.selected,
    required this.paired,
    required this.connected,
    required this.connecting,
    this.address,
    this.bluetoothOnly = false,
    this.audioSource = false,
    this.mediaConnected = false,
  }) : endpoints = List.unmodifiable(endpoints),
       sessions = List.unmodifiable(sessions),
       protocols = Set.unmodifiable(protocols);

  final String id, name, identifier;
  final String? address;
  String? get bluetoothAddress => address;
  final List<ConnectivityDevice> endpoints;
  final List<ProjectionSession> sessions;
  final Set<ProjectionProtocol> protocols;
  final ProjectionProtocol? protocol;
  final bool selected, paired, connected, connecting;
  final bool bluetoothOnly;
  final bool audioSource, mediaConnected;

  ConnectivityDevice? forAdapter(String adapter) =>
      endpoints.where((endpoint) => endpoint.adapterId == adapter).firstOrNull;
  ConnectivityDevice? connectTargetFor(String adapter) => forAdapter(adapter);
  List<ProjectionSession> get liveSessions =>
      List.unmodifiable(sessions.where(_liveSession));
}

bool _liveSession(ProjectionSession session) =>
    session.state != ProjectionSessionState.failed &&
    session.state != ProjectionSessionState.disconnected;

const _connectingPhases = {
  'preparing',
  'bootstrap',
  'connecting',
  'backoff',
  'retrying',
};

String? _addressOfReference(String value) => bluetoothAddress(
  value.startsWith('bluetooth:')
      ? value.substring('bluetooth:'.length)
      : value.split('/').last,
);

String _physicalId(String id, String? address) =>
    address == null ? id : 'bluetooth:$address';

/// Native CarPlay's wireless identity is the first half of SHA-256 over the
/// six Bluetooth address bytes. It is unrelated to the phone's friendly name.
String carPlayWirelessDeviceId(String address) {
  final normalized = bluetoothAddress(address);
  if (normalized == null) throw ArgumentError.value(address, 'address');
  return sha256
      .convert(
        normalized
            .split(':')
            .map((part) => int.parse(part, radix: 16))
            .toList(),
      )
      .bytes
      .take(16)
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
}

Set<String> _projectionAliases(ProjectionProtocol protocol, String id) {
  final prefix = '${protocol.name.toLowerCase()}.device.';
  if (id.startsWith(prefix)) {
    final encoded = id.substring(prefix.length);
    if (encoded.length.isEven && RegExp(r'^[0-9a-f]+$').hasMatch(encoded)) {
      try {
        final local = utf8.decode([
          for (var i = 0; i < encoded.length; i += 2)
            int.parse(encoded.substring(i, i + 2), radix: 16),
        ]);
        return {id, local};
      } on FormatException {
        // Unknown opaque IDs remain exact-match identities.
      }
    }
  }
  final encoded = utf8
      .encode(id)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return {id, '$prefix$encoded'};
}

Set<String> projectionDeviceIdentities(ProjectionDevice device) =>
    Set.unmodifiable(_projectionAliases(device.protocol, device.id));

final class _PhoneRow {
  _PhoneRow(this.id, this.address);
  final String id;
  final String? address;
  final endpoints = <ConnectivityDevice>[];
  final sessions = <ProjectionSession>[];
  final protocols = <ProjectionProtocol>{};
  final names = <String>[];
  final bindings = <ProjectionProtocol, Set<String>>{};
  ProjectionProtocol? chosenProtocol;
  bool remembered = false;
  bool connecting = false;
  bool bluetoothOnly = false;

  String get name =>
      names
          .where(
            (name) =>
                name.trim().isNotEmpty &&
                _addressOfReference(name) == null &&
                name != id,
          )
          .firstOrNull ??
      names.where((name) => name.isNotEmpty).firstOrNull ??
      address ??
      id;
}

/// Joins only proven endpoint identities. Equal aliases and a lone nearby phone
/// are never evidence that a USB projection belongs to a Bluetooth device.
List<DeviceHubDevice> buildDeviceInventory(
  ConnectivitySnapshot connectivity,
  ProjectionSnapshot projection, {
  List<RememberedPhone> remembered = const [],
  String selectedId = '',
  bool carPlayRunning = false,
  String carPlayTarget = '',
}) {
  final rows = <String, _PhoneRow>{};
  _PhoneRow row(String id, String? address) => rows.putIfAbsent(
    _physicalId(id, address),
    () => _PhoneRow(_physicalId(id, address), address),
  );
  for (final group in connectivity.deviceGroups) {
    final current = row(group.id, _addressOfReference(group.identifier));
    current.endpoints.addAll(group.endpoints);
    current.names.add(group.name);
    current.protocols.addAll(group.protocols);
  }
  for (final phone in remembered) {
    final current = row(
      phone.id,
      phone.address ?? _addressOfReference(phone.id),
    );
    current.remembered = true;
    current.names.add(phone.name);
    current.chosenProtocol ??= phone.protocol;
    current.bluetoothOnly = current.bluetoothOnly || phone.bluetoothOnly;
    if (phone.protocol case final protocol?) current.protocols.add(protocol);
    for (final entry in phone.projectionIds.entries) {
      current.protocols.add(entry.key);
      current.bindings.putIfAbsent(entry.key, () => {}).addAll(entry.value);
    }
  }
  final aaAddress = _addressOfReference(connectivity.selected);
  final selectedAa = aaAddress == null ? null : rows['bluetooth:$aaAddress'];
  if (selectedAa != null && _connectingPhases.contains(connectivity.phase)) {
    selectedAa.connecting = true;
    selectedAa.protocols.add(ProjectionProtocol.androidAuto);
  }
  final cpAddress = _addressOfReference(carPlayTarget);
  final cpTargetId = cpAddress == null ? carPlayTarget : 'bluetooth:$cpAddress';
  final cpTarget = rows[cpTargetId];
  if (carPlayRunning && cpTarget != null) {
    cpTarget.connecting = true;
    cpTarget.protocols.add(ProjectionProtocol.carPlay);
  }
  final devices = <(ProjectionProtocol, String), ProjectionDevice>{
    for (final device in projection.devices)
      (device.protocol, device.id): device,
    for (final session in projection.sessions)
      (session.device.protocol, session.device.id): session.device,
  };
  for (final device in devices.values) {
    final protocol = device.protocol;
    final sessions = projection.sessions
        .where((s) => s.device.id == device.id && s.device.protocol == protocol)
        .toList();
    final aliases = _projectionAliases(protocol, device.id);
    final bound = rows.values
        .where(
          (r) =>
              r.bindings[protocol]?.any(
                (id) => _projectionAliases(
                  protocol,
                  id,
                ).intersection(aliases).isNotEmpty,
              ) ??
              false,
        )
        .toList();
    _PhoneRow? current;
    if (bound.length == 1) {
      current = bound.single;
    } else if (bound.isEmpty && device.transport == ProjectionTransport.wifi) {
      if (protocol == ProjectionProtocol.carPlay) {
        final exact = rows.values
            .where(
              (r) =>
                  r.address != null &&
                  aliases.contains(carPlayWirelessDeviceId(r.address!)),
            )
            .toList();
        if (exact.length == 1) current = exact.single;
      } else if (selectedAa != null &&
          (sessions.any(_liveSession) ||
              _connectingPhases.contains(connectivity.phase))) {
        current = selectedAa;
      }
    }
    current ??= row('projection:${protocol.name}:${device.id}', null);
    current.names.add(device.displayName);
    current.protocols.add(protocol);
    current.sessions.addAll(sessions);
  }
  final normalizedSelection = _physicalId(
    selectedId,
    _addressOfReference(selectedId),
  );
  final result = rows.values.map((current) {
    final active = current.sessions.where(_liveSession).toList();
    final established = active.any(
      (session) => session.state != ProjectionSessionState.connecting,
    );
    final activeProtocols = active.map((s) => s.device.protocol).toSet();
    final musicDevice = connectivity.music?['device'] as String? ?? '';
    final musicBelongs =
        current.endpoints.any((e) => e.id == musicDevice) ||
        (current.address != null &&
            current.address == _addressOfReference(musicDevice));
    final musicConnecting =
        current.bluetoothOnly &&
        musicBelongs &&
        const {
          'preparing',
          'connecting',
          'waiting',
          'waiting-audio',
          'retrying',
          'backoff',
        }.contains(connectivity.music?['phase']);
    return DeviceHubDevice(
      id: current.id,
      name: current.name,
      identifier: current.address ?? current.id,
      address: current.address,
      endpoints: current.endpoints,
      sessions: current.sessions,
      protocols: current.protocols,
      protocol: activeProtocols.length == 1
          ? activeProtocols.single
          : current.bluetoothOnly
          ? null
          : current.chosenProtocol ??
                (current.protocols.length == 1
                    ? current.protocols.single
                    : null),
      bluetoothOnly: activeProtocols.isEmpty && current.bluetoothOnly,
      audioSource: current.endpoints.any((e) => e.audioSource),
      mediaConnected:
          musicBelongs &&
          connectivity.music?['phase'] == 'connected' &&
          connectivity.music?['source'] is Map,
      selected: current.id == normalizedSelection,
      paired: current.remembered || current.endpoints.any((e) => e.paired),
      connected: established || current.endpoints.any((e) => e.connected),
      connecting:
          !established &&
          (current.connecting ||
              musicConnecting ||
              active.any((s) => s.state == ProjectionSessionState.connecting)),
    );
  }).toList()..sort((a, b) => a.id.compareTo(b.id));
  return List.unmodifiable(result);
}
