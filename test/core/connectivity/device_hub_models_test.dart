import 'dart:convert';

import 'package:argo/core/connectivity/connectivity_service.dart';
import 'package:argo/core/connectivity/device_hub_models.dart';
import 'package:argo/core/projection/projection_models.dart';
import 'package:argo/core/projection/projection_types.dart';
import 'package:flutter_test/flutter_test.dart';

const _address = 'AA:00:00:00:00:01';
const _otherAddress = 'BB:00:00:00:00:01';
const _phoneId = 'bluetooth:$_address';
const _otherId = 'bluetooth:$_otherAddress';

ProjectionDevice device(
  String id, {
  ProjectionProtocol protocol = ProjectionProtocol.carPlay,
  ProjectionTransport transport = ProjectionTransport.wifi,
  String name = 'My phone',
}) => ProjectionDevice(
  id: id,
  displayName: name,
  protocol: protocol,
  transport: transport,
);

ProjectionSnapshot projected(
  ProjectionDevice device, {
  ProjectionSessionState state = ProjectionSessionState.streaming,
}) => ProjectionSnapshot(
  backendAvailable: true,
  devices: [device],
  sessions: [ProjectionSession(id: 'session', device: device, state: state)],
  activeSessionId: 'session',
);

String qualified(ProjectionProtocol protocol, String id) =>
    '${protocol.name.toLowerCase()}.device.${utf8.encode(id).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

ConnectivitySnapshot bluetooth({
  List<ConnectivityDevice>? devices,
  String selected = 'hci0/$_address',
  String phase = 'idle',
}) => ConnectivitySnapshot(
  available: true,
  daemonConnected: true,
  adapter: 'hci0',
  selected: selected,
  phase: phase,
  adapters: const [
    ConnectivityRadio('hci0', 'Host'),
    ConnectivityRadio('hci2', 'Link'),
  ],
  devices:
      devices ??
      const [ConnectivityDevice('hci0/$_address', 'My phone', true, false)],
);

void main() {
  test('native capability tags union across duplicate Bluetooth routes', () {
    final state = ConnectivitySnapshot.fromJson({
      'adapters': [
        {'id': 'hci0', 'name': 'Host'},
        {'id': 'hci2', 'name': 'Link'},
      ],
      'networks': <Object>[],
      'devices': [
        {
          'id': 'hci0/aa:00:00:00:00:01',
          'name': 'My phone',
          'paired': true,
          'connected': false,
          'protocols': ['android-auto', 'future-protocol'],
        },
        {
          'id': 'hci0/$_address',
          'name': 'My phone',
          'paired': false,
          'connected': true,
          'protocols': ['carplay'],
        },
        {
          'id': 'hci2/$_address',
          'name': 'My phone',
          'paired': true,
          'connected': false,
        },
      ],
      'adapter': 'hci0',
      'interface': '',
      'selected': '',
      'phase': 'idle',
      'detail': 'Ready',
      'enabled': true,
      'discovering': false,
      'wifi_connected': false,
    });
    expect(state.devices, hasLength(2));
    expect(state.deviceGroups, hasLength(1));
    expect(
      state.deviceGroups.single.protocols,
      ProjectionProtocol.values.toSet(),
    );
    expect(state.devices.first.paired && state.devices.first.connected, isTrue);
  });

  test('CarPlay MAC digest joins both controllers and qualified projection exactly once', () {
    // Generated independently using OpenSSL-compatible SHA-256 over six bytes.
    const nativeId = '5c938ab479531bcc2094b925a13c0684';
    expect(carPlayWirelessDeviceId(_address), nativeId);
    final cp = device(qualified(ProjectionProtocol.carPlay, nativeId));
    final rows = buildDeviceInventory(
      bluetooth(
        devices: const [
          ConnectivityDevice('hci2/$_address', 'My phone', true, true),
          ConnectivityDevice('hci0/$_address', 'My phone', true, false),
        ],
      ),
      projected(cp),
      selectedId: _phoneId,
    );
    final phone = rows.single;
    expect(phone.id, _phoneId);
    expect(phone.bluetoothAddress, _address);
    expect(phone.sessions.single.device, cp);
    expect(phone.endpoints, hasLength(2));
    expect(phone.protocol, ProjectionProtocol.carPlay);
    expect(phone.connected && phone.selected && phone.paired, isTrue);
    expect(phone.connecting, isFalse);
    expect(phone.connectTargetFor('hci0')!.id, 'hci0/$_address');
    expect(phone.connectTargetFor('hci9'), isNull);
    expect(() => rows.add(phone), throwsUnsupportedError);
    expect(() => phone.sessions.clear(), throwsUnsupportedError);
  });

  test(
    'AA wireless binds its selected endpoint even when aliases are identical',
    () {
      final aa = device(
        'wireless-device:12345',
        protocol: ProjectionProtocol.androidAuto,
      );
      final rows = buildDeviceInventory(
        bluetooth(
          devices: const [
            ConnectivityDevice('hci0/$_address', 'My phone', true, false),
            ConnectivityDevice('hci0/$_otherAddress', 'My phone', true, true),
          ],
          selected: 'hci0/$_otherAddress',
          phase: 'streaming',
        ),
        projected(aa),
      );
      expect(rows, hasLength(2));
      expect(rows.first.id, _phoneId);
      expect(rows.first.sessions, isEmpty);
      expect(rows.last.id, _otherId);
      expect(rows.last.sessions.single.device.id, aa.id);
      expect(rows.last.protocol, ProjectionProtocol.androidAuto);
    },
  );

  test('AA pending startup marks only the chosen phone and does not identify idle peers', () {
    final rows = buildDeviceInventory(
      bluetooth(
        phase: 'bootstrap',
        devices: const [
          ConnectivityDevice('hci0/$_address', 'My phone', true, false),
          ConnectivityDevice('hci0/$_otherAddress', 'My phone', true, false),
        ],
      ),
      const ProjectionSnapshot.disabled(),
    );
    expect(rows.first.connecting, isTrue);
    expect(rows.first.protocol, ProjectionProtocol.androidAuto);
    expect(rows.last.connecting, isFalse);
    expect(rows.last.protocol, isNull);
  });

  test('USB never joins Bluetooth by name; explicit protocol binding proves the association', () {
    final usb = device('usb-opaque-id', transport: ProjectionTransport.usb);
    final unrelated = buildDeviceInventory(bluetooth(), projected(usb));
    expect(unrelated, hasLength(2));
    expect(unrelated.first.id, _phoneId);
    expect(unrelated.first.sessions, isEmpty);
    expect(unrelated.last.id, 'projection:carPlay:usb-opaque-id');
    final remembered = RememberedPhone(
      id: _phoneId,
      address: _address,
      name: 'My phone',
      protocol: ProjectionProtocol.carPlay,
      projectionIds: {
        ProjectionProtocol.carPlay: {'usb-opaque-id'},
      },
    );
    final proven = buildDeviceInventory(
      bluetooth(),
      projected(
        device(
          qualified(ProjectionProtocol.carPlay, usb.id),
          transport: ProjectionTransport.usb,
        ),
      ),
      remembered: [remembered],
    );
    expect(proven, hasLength(1));
    expect(proven.single.sessions, hasLength(1));
  });

  test(
    'saved session binding takes precedence over a later selected AA phone',
    () {
      final aa = device('old-aa', protocol: ProjectionProtocol.androidAuto);
      final rows = buildDeviceInventory(
        bluetooth(
          selected: 'hci0/$_otherAddress',
          devices: const [
            ConnectivityDevice('hci0/$_address', 'Original', true, false),
            ConnectivityDevice(
              'hci0/$_otherAddress',
              'New selection',
              true,
              false,
            ),
          ],
        ),
        projected(aa, state: ProjectionSessionState.failed),
        remembered: [
          RememberedPhone(
            id: _phoneId,
            name: 'Original',
            address: _address,
            projectionIds: {
              ProjectionProtocol.androidAuto: {aa.id},
            },
          ),
        ],
      );
      expect(rows.first.sessions.single.state, ProjectionSessionState.failed);
      expect(rows.first.connected || rows.first.connecting, isFalse);
      expect(rows.last.sessions, isEmpty);
    },
  );

  test('ambiguous stored projection bindings stay separate instead of choosing a phone', () {
    final cp = device('usb-id', transport: ProjectionTransport.usb);
    final rows = buildDeviceInventory(
      const ConnectivitySnapshot(),
      projected(cp),
      remembered: [
        for (final address in [_address, _otherAddress])
          RememberedPhone(
            id: 'bluetooth:$address',
            name: 'Same alias',
            address: address,
            projectionIds: {
              ProjectionProtocol.carPlay: {'usb-id'},
            },
          ),
      ],
    );
    expect(rows, hasLength(3));
    expect(rows.take(2).every((row) => row.sessions.isEmpty), isTrue);
    expect(rows.last.sessions, hasLength(1));
  });

  test('vanished Link route keeps one remembered row and only its target can connect', () {
    final remembered = [
      for (final address in [_address, _otherAddress])
        RememberedPhone(
          id: 'bluetooth:$address',
          name: 'Offline iPhone',
          address: address,
          protocol: ProjectionProtocol.carPlay,
        ),
    ];
    final idle = buildDeviceInventory(
      const ConnectivitySnapshot(),
      const ProjectionSnapshot.disabled(),
      remembered: remembered,
      selectedId: _phoneId,
      carPlayRunning: true,
    );
    expect(idle.every((row) => !row.connecting), isTrue);
    final connecting = buildDeviceInventory(
      const ConnectivitySnapshot(),
      const ProjectionSnapshot.disabled(),
      remembered: remembered,
      selectedId: _phoneId,
      carPlayRunning: true,
      carPlayTarget: _address.toLowerCase(),
    );
    expect(connecting.first.id, _phoneId);
    expect(connecting.first.selected && connecting.first.paired, isTrue);
    expect(connecting.first.connected, isFalse);
    expect(connecting.first.connecting, isTrue);
    expect(connecting.last.connecting, isFalse);
    expect(connecting.first.endpoints, isEmpty);
  });

  test(
    'capability ambiguity requires a choice and confirmed live protocol wins',
    () {
      final state = bluetooth(
        devices: const [
          ConnectivityDevice(
            'hci0/$_address',
            'My phone',
            true,
            false,
            protocols: {
              ProjectionProtocol.androidAuto,
              ProjectionProtocol.carPlay,
            },
          ),
        ],
      );
      expect(
        buildDeviceInventory(
          state,
          const ProjectionSnapshot.disabled(),
        ).single.protocol,
        isNull,
      );
      final saved = RememberedPhone(
        id: _phoneId,
        name: 'My phone',
        address: _address,
        protocol: ProjectionProtocol.androidAuto,
      );
      expect(
        buildDeviceInventory(
          state,
          const ProjectionSnapshot.disabled(),
          remembered: [saved],
        ).single.protocol,
        ProjectionProtocol.androidAuto,
      );
      expect(
        buildDeviceInventory(
          state,
          projected(device('5c938ab479531bcc2094b925a13c0684')),
          remembered: [saved],
        ).single.protocol,
        ProjectionProtocol.carPlay,
      );
    },
  );

  test('row identity and order survive reversed discovery, status and alias changes', () {
    const first = ConnectivityDevice('hci0/$_address', 'Z name', true, false);
    const second = ConnectivityDevice(
      'hci0/$_otherAddress',
      'A name',
      true,
      true,
    );
    final before = buildDeviceInventory(
      bluetooth(devices: [first, second]),
      const ProjectionSnapshot.disabled(),
    );
    final after = buildDeviceInventory(
      bluetooth(
        devices: const [
          ConnectivityDevice('hci2/$_otherAddress', 'Z renamed', true, false),
          ConnectivityDevice('hci2/$_address', 'A renamed', true, true),
        ],
      ),
      const ProjectionSnapshot.disabled(),
    );
    expect(after.map((row) => row.id), before.map((row) => row.id));
    expect(after.first.name, 'A renamed');
  });

  test('explicit Bluetooth-only choice survives capability discovery until real projection connects', () {
    final state = bluetooth(
      devices: const [
        ConnectivityDevice(
          'hci0/$_address',
          'My phone',
          true,
          false,
          protocols: {ProjectionProtocol.carPlay},
        ),
      ],
    );
    final phone = RememberedPhone(
      id: _phoneId,
      name: 'My phone',
      address: _address,
      bluetoothOnly: true,
    );
    final restored = RememberedPhone.fromJson(phone.toJson());
    expect(restored.bluetoothOnly, isTrue);
    final idle = buildDeviceInventory(
      state,
      const ProjectionSnapshot.disabled(),
      remembered: [restored],
    ).single;
    expect(idle.protocol, isNull);
    expect(idle.bluetoothOnly, isTrue);
    final live = buildDeviceInventory(
      state,
      projected(device('5c938ab479531bcc2094b925a13c0684')),
      remembered: [restored],
    ).single;
    expect(live.protocol, ProjectionProtocol.carPlay);
    expect(live.bluetoothOnly, isFalse);
  });

  test('remembered records round trip bounded identity and immutable protocol bindings', () {
    final phone = RememberedPhone(
      id: _phoneId,
      name: 'My phone',
      address: _address.toLowerCase(),
      protocol: ProjectionProtocol.carPlay,
      projectionIds: {
        ProjectionProtocol.carPlay: {'second-id', 'first-id'},
      },
    );
    final restored = RememberedPhone.fromJson(
      jsonDecode(jsonEncode(phone.toJson())),
    );
    expect(restored.toJson(), phone.toJson());
    expect(restored.address, _address);
    expect(
      () => restored.projectionIds[ProjectionProtocol.carPlay]!.add('x'),
      throwsUnsupportedError,
    );
    expect(
      () => RememberedPhone.fromJson({
        'id': 'x',
        'name': 'Phone',
        'protocol': 'unknown',
      }),
      throwsFormatException,
    );
    expect(
      () => RememberedPhone.fromJson({
        'id': 'x',
        'name': 'Phone',
        'address': 'not-a-mac',
      }),
      throwsFormatException,
    );
    expect(
      () => RememberedPhone.fromJson({
        'id': 'x',
        'name': 'Phone',
        'projection_ids': {'carplay': List.filled(33, 'id')},
      }),
      throwsFormatException,
    );
  });
}
