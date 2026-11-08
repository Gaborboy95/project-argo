import 'dart:async';
import 'dart:convert';

import 'package:argo/core/connectivity/connectivity_service.dart';
import 'package:argo/core/connectivity/device_connection_service.dart';
import 'package:argo/core/connectivity/device_hub_models.dart';
import 'package:argo/core/diagnostics/service_failure.dart';
import 'package:argo/core/projection/carplay_settings_service.dart';
import 'package:argo/core/projection/projection_models.dart';
import 'package:argo/core/projection/projection_service.dart';
import 'package:argo/core/projection/projection_types.dart';
import 'package:argo/core/settings/app_setting_keys.dart';
import 'package:argo/core/settings/settings_service.dart';
import 'package:argo/core/settings/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

const _aaAddress = '02:00:00:00:00:01';
const _cpAddress = '02:00:00:00:00:02';
const _otherAddress = '02:00:00:00:00:03';
const _aa = 'bluetooth:$_aaAddress';
const _cp = 'bluetooth:$_cpAddress';
const _other = 'bluetooth:$_otherAddress';
const _aaEndpoint = 'hci0/$_aaAddress';
const _cpEndpoint = 'hci1/$_cpAddress';
const _otherEndpoint = 'hci0/$_otherAddress';

void main() {
  test('startup requests only the selected Android Auto phone once', () async {
    final fixture = await _Fixture.create(selected: _aa, auto: true);
    addTearDown(fixture.close);
    await _drain();
    expect(
      fixture.calls.where((call) => call == 'aa.connect:$_aaEndpoint'),
      hasLength(1),
    );
    expect(
      fixture.calls.where((call) => call.startsWith('cp.connect')),
      isEmpty,
    );
    fixture.backend.publish();
    fixture.carPlay.publish();
    await _drain();
    expect(
      fixture.calls.where((call) => call == 'aa.connect:$_aaEndpoint'),
      hasLength(1),
    );
    expect(fixture.hub.selectedId, _aa);
    expect(fixture.hub.error, isNull);
  });

  test('startup restores one cached CarPlay phone while its virtual controller is absent', () async {
    final fixture = await _Fixture.create(
      selected: _cp,
      auto: true,
      phones: const [],
      remembered: [
        RememberedPhone(
          id: _cp,
          name: 'Remembered iPhone',
          address: _cpAddress,
          protocol: ProjectionProtocol.carPlay,
        ),
      ],
    );
    addTearDown(fixture.close);
    await _drain();
    expect(
      fixture.calls.where((call) => call == 'cp.connect:$_cpAddress'),
      hasLength(1),
    );
    expect(
      fixture.calls.where((call) => call.startsWith('aa.connect')),
      isEmpty,
    );
    expect(fixture.hub.devices.single.id, _cp);
    expect(fixture.hub.devices.single.endpoints, isEmpty);
    expect(fixture.carPlay.current['target'], _cpAddress);
    expect(fixture.hub.error, isNull);
  });

  test(
    'startup never guesses Android Auto for an unknown Bluetooth device',
    () async {
      final fixture = await _Fixture.create(
        selected: _other,
        auto: true,
        phones: [_phone(_otherEndpoint)],
      );
      addTearDown(fixture.close);
      await _drain();
      expect(fixture.calls, isEmpty);
      expect(fixture.hub.devices.single.protocol, isNull);
    },
  );

  test(
    'switch to Android Auto waits until CarPlay cleanup is confirmed',
    () async {
      final fixture = await _Fixture.create(selected: _cp);
      addTearDown(fixture.close);
      fixture.carPlay.autoStop = false;
      fixture.carPlay.publish(
        running: true,
        phase: 'Connected',
        target: _cpAddress,
      );
      fixture.backend.setConnected(_cpEndpoint, true);
      fixture.projection.show(ProjectionProtocol.carPlay, _cpAddress);
      final operation = fixture.hub.connect(_aa);
      await _drain();
      expect(fixture.calls, contains('cp.disconnect'));
      expect(
        fixture.calls.where((call) => call.startsWith('aa.connect')),
        isEmpty,
      );
      expect(fixture.hub.busy, isTrue);
      fixture.finishCarPlay();
      await operation;
      expect(fixture.hub.error, isNull);
      expect(
        fixture.calls.indexOf('cp.disconnect'),
        lessThan(fixture.calls.indexOf('aa.connect:$_aaEndpoint')),
      );
      expect(fixture.hub.selectedId, _aa);
    },
  );

  test('switch to CarPlay waits through Android Auto cleanup', () async {
    final fixture = await _Fixture.create(selected: _aa);
    addTearDown(fixture.close);
    fixture.backend.autoStop = false;
    fixture.backend.phase = 'streaming';
    fixture.backend.setConnected(_aaEndpoint, true);
    fixture.projection.show(ProjectionProtocol.androidAuto, _aaAddress);
    final operation = fixture.hub.connect(_cp);
    await _drain();
    expect(fixture.calls, contains('aa.disconnect:'));
    expect(
      fixture.calls.where((call) => call.startsWith('cp.connect')),
      isEmpty,
    );
    fixture.finishAndroidAuto();
    await operation;
    expect(fixture.hub.error, isNull);
    expect(
      fixture.calls.indexOf('aa.disconnect:'),
      lessThan(fixture.calls.indexOf('cp.connect:$_cpAddress')),
    );
    expect(fixture.hub.selectedId, _cp);
  });

  test(
    'disconnecting another Bluetooth device preserves the active phone',
    () async {
      final fixture = await _Fixture.create(
        selected: _aa,
        phones: [
          _phone(
            _aaEndpoint,
            protocol: ProjectionProtocol.androidAuto,
            connected: true,
          ),
          _phone(_otherEndpoint, connected: true),
        ],
      );
      addTearDown(fixture.close);
      fixture.backend.phase = 'streaming';
      fixture.backend.publish();
      fixture.projection.show(ProjectionProtocol.androidAuto, _aaAddress);
      final active = fixture.projection.current.sessions.single;
      await fixture.hub.disconnect(_other);
      expect(fixture.calls, ['aa.deviceDisconnect:$_otherEndpoint']);
      expect(fixture.backend.phase, 'streaming');
      expect(fixture.projection.current.sessions.single, same(active));
      expect(fixture.hub.selectedId, _aa);
      expect(fixture.hub.error, isNull);
    },
  );

  test('explicit device disconnect suppresses the remaining startup reconnect intent', () async {
    final fixture = await _Fixture.create(selected: _aa, auto: true);
    addTearDown(fixture.close);
    await _drain();
    await fixture.hub.disconnect(_aa);
    fixture.backend.phase = 'idle';
    fixture.backend.publish();
    fixture.carPlay.publish();
    await _drain();
    expect(
      fixture.calls.where((call) => call == 'aa.connect:$_aaEndpoint'),
      hasLength(1),
    );
    expect(fixture.calls, contains('aa.deviceDisconnect:$_aaEndpoint'));
    expect(fixture.hub.autoConnect, isTrue);
    expect(fixture.hub.error, isNull);
  });

  test('a rejected CarPlay stop prevents starting Android Auto', () async {
    final fixture = await _Fixture.create(selected: _cp);
    addTearDown(fixture.close);
    fixture.carPlay.failStop = true;
    fixture.carPlay.publish(
      running: true,
      phase: 'Connected',
      target: _cpAddress,
    );
    await fixture.hub.connect(_aa);
    expect(fixture.calls, contains('cp.disconnect'));
    expect(
      fixture.calls.where((call) => call.startsWith('aa.connect')),
      isEmpty,
    );
    expect(fixture.hub.error, contains('Synthetic CarPlay cleanup failure'));
  });

  test('a previously acknowledged CarPlay stop still blocks handoff during cleanup', () async {
    final fixture = await _Fixture.create(selected: _cp);
    addTearDown(fixture.close);
    fixture.carPlay.publish(
      running: false,
      phase: 'Disconnecting',
      target: _cpAddress,
    );
    final operation = fixture.hub.connect(_aa);
    await _drain();
    expect(
      fixture.calls.where((call) => call.startsWith('aa.connect')),
      isEmpty,
    );
    fixture.finishCarPlay();
    await operation;
    expect(fixture.hub.error, isNull);
    expect(fixture.calls, contains('aa.connect:$_aaEndpoint'));
  });

  test(
    'an existing Android Auto cleanup failure blocks another phone protocol',
    () async {
      final fixture = await _Fixture.create(selected: _aa);
      addTearDown(fixture.close);
      fixture.backend.phase = 'disconnected';
      fixture.backend.cleanupError = 'Synthetic Android Auto cleanup failure';
      fixture.backend.publish();
      await fixture.hub.connect(_cp);
      expect(
        fixture.calls.where((call) => call.startsWith('cp.connect')),
        isEmpty,
      );
      expect(
        fixture.hub.error,
        contains('Synthetic Android Auto cleanup failure'),
      );
    },
  );

  test(
    'adding an iPhone binds the native selected peer to one remembered device',
    () async {
      final fixture = await _Fixture.create(selected: '', phones: const []);
      addTearDown(fixture.close);
      await fixture.hub.beginPairing(ProjectionProtocol.carPlay);
      expect(fixture.calls, ['cp.connect:']);
      expect(fixture.hub.pairingProtocol, ProjectionProtocol.carPlay);
      fixture.carPlay.publish(target: _cpAddress);
      fixture.backend.phones = [
        _phone(
          _cpEndpoint,
          protocol: ProjectionProtocol.carPlay,
          connected: true,
        ),
      ];
      fixture.backend.publish();
      fixture.projection.show(ProjectionProtocol.carPlay, _cpAddress);
      await _drain();
      expect(fixture.hub.selectedId, _cp);
      expect(fixture.hub.pairingProtocol, isNull);
      expect(fixture.hub.devices, hasLength(1));
      expect(fixture.hub.devices.single.sessions, hasLength(1));
      expect(fixture.hub.devices.single.protocol, ProjectionProtocol.carPlay);
      expect(fixture.settings.get(AppSettingKeys.selectedDevice), _cp);
      expect(fixture.hub.error, isNull);
    },
  );

  test('Bluetooth source phones connect their media receiver while headsets remain output devices', () async {
    for (final audioSource in [true, false]) {
      final fixture = await _Fixture.create(
        selected: _other,
        phones: [_phone(_otherEndpoint, audioSource: audioSource)],
      );
      await fixture.hub.selectProtocol(_other, null);
      await fixture.hub.connect(_other);
      expect(
        fixture.calls.where((call) => call.startsWith('aa.deviceConnect:')),
        ['aa.deviceConnect:$_otherEndpoint'],
      );
      expect(
        fixture.calls.where((call) => call.startsWith('aa.musicConnect:')),
        audioSource ? ['aa.musicConnect:$_otherEndpoint'] : isEmpty,
      );
      expect(fixture.hub.devices.single.audioSource, audioSource);
      expect(fixture.hub.devices.single.mediaConnected, audioSource);
      expect(fixture.hub.error, isNull);
      await fixture.close();
    }
  });

  test('a grouped phone routes music only through an endpoint with positive source capability', () async {
    final fixture = await _Fixture.create(
      selected: _other,
      phones: [
        _phone(_otherEndpoint),
        _phone('hci1/$_otherAddress', audioSource: true),
      ],
    );
    addTearDown(fixture.close);
    await fixture.hub.selectProtocol(_other, null);
    await fixture.hub.connect(_other);
    expect(fixture.calls.where((call) => call.startsWith('aa.musicConnect:')), [
      'aa.musicConnect:hci1/$_otherAddress',
    ]);
    expect(fixture.hub.devices, hasLength(1));
    expect(fixture.hub.devices.single.mediaConnected, isTrue);
    expect(fixture.hub.error, isNull);
  });

  test(
    'a rejected Bluetooth receiver connection remains a visible media error',
    () async {
      final fixture = await _Fixture.create(
        selected: _other,
        phones: [_phone(_otherEndpoint, audioSource: true)],
      );
      addTearDown(fixture.close);
      fixture.backend.musicFailure = 'Phone audio receiver is unavailable';
      await fixture.hub.selectProtocol(_other, null);
      await fixture.hub.connect(_other);
      expect(fixture.calls, contains('aa.musicConnect:$_otherEndpoint'));
      expect(fixture.hub.devices.single.mediaConnected, isFalse);
      expect(
        fixture.hub.error,
        contains('Phone audio receiver is unavailable'),
      );
      expect(fixture.hub.busy, isFalse);
    },
  );

  test(
    'a Bluetooth-only choice survives snapshots and uses device connection',
    () async {
      final fixture = await _Fixture.create(
        phones: [_phone(_aaEndpoint, protocol: ProjectionProtocol.androidAuto)],
      );
      addTearDown(fixture.close);
      await fixture.hub.selectProtocol(_aa, null);
      fixture.backend.publish();
      fixture.carPlay.publish();
      await _drain();
      expect(fixture.hub.devices.single.bluetoothOnly, isTrue);
      expect(fixture.hub.devices.single.protocol, isNull);
      final cache = jsonDecode(
        fixture.settings.get(AppSettingKeys.deviceInventory),
      ) as List;
      expect(cache.single['bluetooth_only'], isTrue);
      await fixture.hub.connect(_aa);
      expect(fixture.calls, ['aa.deviceConnect:$_aaEndpoint']);
      expect(fixture.hub.devices.single.connected, isTrue);
      expect(fixture.hub.error, isNull);
    },
  );

  test(
    'adding Android Auto automatically connects only the newly paired phone',
    () async {
      final fixture = await _Fixture.create(selected: _aa);
      addTearDown(fixture.close);
      await fixture.hub.beginPairing(ProjectionProtocol.androidAuto);
      fixture.backend.phones = [
        ...fixture.backend.phones,
        _phone(_otherEndpoint, protocol: ProjectionProtocol.androidAuto),
      ];
      fixture.backend.publish();
      await _drain();
      expect(fixture.hub.selectedId, _other);
      expect(fixture.hub.pairingProtocol, isNull);
      expect(fixture.calls.where((call) => call.startsWith('aa.connect:')), [
        'aa.connect:$_otherEndpoint',
      ]);
      expect(
        fixture.calls.where((call) => call.startsWith('cp.connect:')),
        isEmpty,
      );
      fixture.backend.publish();
      await _drain();
      expect(
        fixture.calls.where((call) => call == 'aa.connect:$_otherEndpoint'),
        hasLength(1),
      );
      expect(fixture.hub.error, isNull);
    },
  );

  test(
    'forget confirms bond removal before stopping the Link receiver',
    () async {
      final fixture = await _Fixture.create(selected: _cp);
      addTearDown(fixture.close);
      fixture.carPlay.publish(
        running: true,
        phase: 'Connected',
        target: _cpAddress,
      );
      fixture.carPlay.afterStop = fixture.projection.clear;
      fixture.backend.setConnected(_cpEndpoint, true);
      fixture.projection.show(ProjectionProtocol.carPlay, _cpAddress);
      fixture.backend.autoForget = false;
      final operation = fixture.hub.forget(_cp);
      await _drain();
      expect(fixture.calls, contains('aa.forget:$_cpEndpoint'));
      expect(fixture.calls, isNot(contains('cp.disconnect')));
      fixture.backend.removeDevice(_cpEndpoint);
      await operation;
      await _drain();
      expect(
        fixture.calls.indexOf('aa.forget:$_cpEndpoint'),
        lessThan(fixture.calls.indexOf('cp.disconnect')),
      );
      expect(fixture.hub.devices.any((device) => device.id == _cp), isFalse);
      expect(fixture.hub.selectedId, isEmpty);
      expect(
        fixture.backend.phones
            .where((phone) => phone.id == _aaEndpoint)
            .single
            .paired,
        isTrue,
      );
      expect(fixture.hub.error, isNull);
    },
  );

  test(
    'disconnect cancels an in-flight device selection before protocol connect',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final selected = Completer<void>();
      fixture.backend.selectionGate = selected;
      final connecting = fixture.hub.connect(_aa);
      await _drain();
      expect(fixture.calls, contains('aa.select:$_aaEndpoint'));
      final stopping = fixture.hub.disconnect(_aa);
      selected.complete();
      await Future.wait([connecting, stopping]);
      expect(
        fixture.calls.where((call) => call.startsWith('aa.connect:')),
        isEmpty,
      );
      expect(fixture.calls, contains('aa.deviceDisconnect:$_aaEndpoint'));
      expect(fixture.hub.error, isNull);
      expect(fixture.hub.busy, isFalse);
    },
  );

  test(
    'one device disconnect closes its connected endpoints on both controllers',
    () async {
      final fixture = await _Fixture.create(
        selected: _cp,
        phones: [
          _phone(
            'hci0/$_cpAddress',
            protocol: ProjectionProtocol.carPlay,
            connected: true,
          ),
          _phone(
            _cpEndpoint,
            protocol: ProjectionProtocol.carPlay,
            connected: true,
          ),
        ],
      );
      addTearDown(fixture.close);
      expect(fixture.hub.devices, hasLength(1));
      await fixture.hub.disconnect(_cp);
      expect(
        fixture.calls
            .where((call) => call.startsWith('aa.deviceDisconnect:'))
            .toList(),
        [
          'aa.deviceDisconnect:hci0/$_cpAddress',
          'aa.deviceDisconnect:$_cpEndpoint',
        ],
      );
      expect(fixture.hub.devices.single.connected, isFalse);
      expect(fixture.hub.error, isNull);
    },
  );

  test(
    'an unconfigured device cannot stop or replace the healthy selected phone',
    () async {
      final fixture = await _Fixture.create(
        selected: _cp,
        phones: [
          _phone(
            _cpEndpoint,
            protocol: ProjectionProtocol.carPlay,
            connected: true,
          ),
          _phone(_otherEndpoint),
        ],
      );
      addTearDown(fixture.close);
      fixture.carPlay.publish(
        running: true,
        phase: 'Connected',
        target: _cpAddress,
      );
      fixture.projection.show(ProjectionProtocol.carPlay, _cpAddress);
      final session = fixture.projection.current.sessions.single;
      await fixture.hub.connect(_other);
      expect(fixture.calls, isEmpty);
      expect(fixture.hub.selectedId, _cp);
      expect(fixture.carPlay.current['running'], isTrue);
      expect(fixture.projection.current.sessions.single, same(session));
      expect(fixture.hub.error, contains('connection type'));
    },
  );

  test('observer errors retain inventory and block connects until every source recovers', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final ids = fixture.hub.devices.map((device) => device.id).toList();
    fixture.backend.events.addError(
      StateError('Synthetic Bluetooth observer failure'),
    );
    fixture.projection.events.addError(
      StateError('Synthetic projection observer failure'),
    );
    fixture.carPlay.events.addError(
      StateError('Synthetic CarPlay observer failure'),
    );
    expect(fixture.hub.devices.map((device) => device.id).toList(), ids);
    expect(fixture.hub.error, contains('temporarily unavailable'));
    await fixture.hub.connect(_aa);
    expect(fixture.calls, isEmpty);
    fixture.backend.publish();
    fixture.projection.clear();
    expect(fixture.hub.error, isNotNull);
    fixture.carPlay.publish();
    expect(fixture.hub.error, isNull);
    expect(fixture.hub.selectedId, _aa);
    await fixture.hub.connect(_aa);
    expect(fixture.calls.where((call) => call.startsWith('aa.connect:')), [
      'aa.connect:$_aaEndpoint',
    ]);
    expect(fixture.hub.error, isNull);
  });
  test('observer recovery never rearms a pending startup connection', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    fixture.backend.wirelessReady = false;
    await fixture.hub.setAutoConnect(true);
    fixture.backend.publish();
    fixture.backend.events.addError(
      StateError('Synthetic startup observer loss'),
    );
    fixture.backend.wirelessReady = true;
    fixture.backend.publish();
    fixture.projection.clear();
    fixture.carPlay.publish();
    await _drain();
    expect(fixture.calls, isEmpty);
    expect(fixture.hub.autoConnect, isTrue);
    expect(fixture.hub.error, isNull);
    await fixture.hub.connect(_aa);
    expect(fixture.calls.where((call) => call.startsWith('aa.connect:')), [
      'aa.connect:$_aaEndpoint',
    ]);
  });

  test('confirmed USB identity joins exactly one phone while retaining its live stream', () async {
    final fixture = await _Fixture.create(
      selected: _cp,
      phones: const [
        ConnectivityDevice(
          _cpEndpoint,
          'Same phone name',
          true,
          false,
          protocols: {ProjectionProtocol.carPlay},
        ),
        ConnectivityDevice(
          _otherEndpoint,
          'Same phone name',
          true,
          false,
          protocols: {ProjectionProtocol.carPlay},
        ),
      ],
    );
    addTearDown(fixture.close);
    fixture.projection.show(
      ProjectionProtocol.carPlay,
      _cpAddress,
      transport: ProjectionTransport.usb,
      deviceId: 'usb-opaque-identity',
      name: 'Same phone name',
    );
    await _drain();
    final usb = fixture.hub.devices.singleWhere(
      (device) => device.bluetoothAddress == null,
    );
    final live = fixture.projection.current.sessions.single;
    expect(fixture.hub.devices, hasLength(3));
    expect(fixture.hub.selectedId, usb.id);
    await fixture.hub.linkDevice(usb.id, _cp);
    await _drain();
    expect(fixture.calls, isEmpty);
    expect(fixture.hub.devices, hasLength(2));
    expect(fixture.hub.selectedId, _cp);
    expect(fixture.projection.current.sessions.single, same(live));
    expect(
      fixture.hub.devices
          .singleWhere((device) => device.id == _cp)
          .sessions
          .single,
      same(live),
    );
    expect(
      fixture.hub.devices.singleWhere((device) => device.id == _other).sessions,
      isEmpty,
    );
    final cache = jsonDecode(
      fixture.settings.get(AppSettingKeys.deviceInventory),
    ) as List;
    final saved = cache.singleWhere((phone) => phone['id'] == _cp) as Map;
    expect(saved['projection_ids']['carplay'], ['usb-opaque-identity']);
    expect(cache.any((phone) => phone['id'] == usb.id), isFalse);
    expect(fixture.hub.error, isNull);
  });
  test('prepareExit cancels waiting startup and drains an in-flight selection before returning', () async {
    final waiting = await _Fixture.create();
    addTearDown(waiting.close);
    waiting.backend.wirelessReady = false;
    await waiting.hub.setAutoConnect(true);
    waiting.backend.publish();
    await waiting.hub.prepareExit();
    waiting.backend.wirelessReady = true;
    waiting.backend.publish();
    waiting.carPlay.publish();
    await _drain();
    expect(waiting.calls, isEmpty);

    final active = await _Fixture.create();
    addTearDown(active.close);
    final selection = Completer<void>();
    active.backend.selectionGate = selection;
    final connecting = active.hub.connect(_aa);
    await _drain();
    expect(active.calls, contains('aa.select:$_aaEndpoint'));
    var prepared = false;
    final preparing = active.hub.prepareExit().then((_) => prepared = true);
    await _drain();
    expect(prepared, isFalse);
    selection.complete();
    await Future.wait([connecting, preparing]);
    active.backend.publish();
    active.carPlay.publish();
    await _drain();
    expect(prepared, isTrue);
    expect(
      active.calls.where(
        (call) =>
            call.startsWith('aa.connect:') || call.startsWith('cp.connect:'),
      ),
      isEmpty,
    );
    expect(active.hub.error, isNull);
    final pairing = await _Fixture.create();
    addTearDown(pairing.close);
    await pairing.hub.beginPairing(ProjectionProtocol.androidAuto);
    final beforeQuit = List.of(pairing.calls);
    await pairing.hub.prepareExit();
    pairing.backend.phones = [
      ...pairing.backend.phones,
      _phone(_otherEndpoint, protocol: ProjectionProtocol.androidAuto),
    ];
    pairing.backend.publish();
    pairing.projection.show(ProjectionProtocol.carPlay, _cpAddress);
    pairing.carPlay.publish(
      running: true,
      phase: 'Connected',
      target: _cpAddress,
    );
    await _drain();
    expect(pairing.calls, beforeQuit);
    expect(pairing.hub.selectedId, _aa);
    expect(pairing.hub.busy, isTrue);
  });
}

Future<void> _drain() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

ConnectivityDevice _phone(
  String endpoint, {
  ProjectionProtocol? protocol,
  bool connected = false,
  bool audioSource = false,
}) => ConnectivityDevice(
  endpoint,
  endpoint == _aaEndpoint
      ? 'Android fixture'
      : endpoint == _cpEndpoint
      ? 'iPhone fixture'
      : 'Bluetooth fixture',
  true,
  connected,
  protocols: {?protocol},
  audioSource: audioSource,
);

class _Fixture {
  _Fixture(
    this.settings,
    this.backend,
    this.projection,
    this.carPlay,
    this.calls,
  );
  final SettingsService settings;
  final _Connectivity backend;
  final _Projection projection;
  final _CarPlay carPlay;
  final List<String> calls;
  late final DeviceConnectionService hub;

  static Future<_Fixture> create({
    String selected = _aa,
    bool auto = false,
    List<ConnectivityDevice>? phones,
    List<RememberedPhone> remembered = const [],
  }) async {
    final settings = await SettingsService.load(
      schema: AppSettingKeys.createSchema(),
      store: _Store(),
    );
    await settings.set(AppSettingKeys.autoConnectPhone, auto);
    await settings.set(AppSettingKeys.selectedDevice, selected);
    await settings.set(
      AppSettingKeys.deviceInventory,
      jsonEncode(remembered.map((phone) => phone.toJson()).toList()),
    );
    final calls = <String>[];
    final backend = _Connectivity(
      calls,
      phones ??
          [
            _phone(_aaEndpoint, protocol: ProjectionProtocol.androidAuto),
            _phone(_cpEndpoint, protocol: ProjectionProtocol.carPlay),
          ],
    );
    final projection = _Projection(calls);
    final carPlay = _CarPlay(calls);
    final fixture = _Fixture(settings, backend, projection, carPlay, calls);
    fixture.hub = DeviceConnectionService(
      backend: backend,
      projection: projection,
      settings: settings,
      carPlay: carPlay,
      operationTimeout: const Duration(milliseconds: 300),
    );
    return fixture;
  }

  void finishCarPlay() {
    projection.clear();
    backend.setConnected(_cpEndpoint, false);
    carPlay.publish(running: false, phase: 'Disconnected');
  }

  void finishAndroidAuto() {
    projection.clear();
    backend.phase = 'disconnected';
    backend.setConnected(_aaEndpoint, false);
  }

  Future<void> close() async {
    await hub.close();
    await backend.events.close();
    await projection.close();
    await carPlay.close();
    await settings.close();
  }
}

class _Connectivity implements ConnectivityService {
  _Connectivity(this.calls, this.phones);
  final List<String> calls;
  List<ConnectivityDevice> phones;
  final events = StreamController<ConnectivitySnapshot>.broadcast(sync: true);
  String phase = 'idle',
      selected = _aaEndpoint,
      adapter = 'hci0',
      cleanupError = '';
  bool autoStop = true, autoForget = true, wirelessReady = true;
  Completer<void>? selectionGate;
  String? musicFailure;
  Map<String, dynamic> music = {
    'phase': 'disconnected',
    'device': '',
    'selected': 'projection',
  };
  @override
  ConnectivitySnapshot get connectivity => ConnectivitySnapshot(
    available: true,
    daemonConnected: true,
    enabled: wirelessReady,
    wirelessAvailable: wirelessReady,
    phase: phase,
    selected: selected,
    adapter: adapter,
    cleanupError: cleanupError,
    adapters: const [
      ConnectivityRadio('hci0', 'Host'),
      ConnectivityRadio('hci1', 'Link'),
    ],
    devices: phones,
    music: music,
  );
  @override
  Stream<ConnectivitySnapshot> get connectivityChanges => events.stream;
  void publish() => events.add(connectivity);
  void removeDevice(String id) {
    phones = phones.where((phone) => phone.id != id).toList();
    publish();
  }

  void setConnected(String id, bool value) {
    phones = [
      for (final phone in phones)
        if (phone.id == id)
          ConnectivityDevice(
            phone.id,
            phone.name,
            phone.paired,
            value,
            protocols: phone.protocols,
            audioSource: phone.audioSource,
          )
        else
          phone,
    ];
    publish();
  }

  @override
  Future<void> connectivityCommand(
    String action, {
    String target = '',
    bool accept = false,
    int prompt = 0,
  }) async {
    calls.add('aa.$action:$target');
    switch (action) {
      case 'adapter':
        adapter = target;
        publish();
      case 'select':
        await selectionGate?.future;
        selected = target;
        publish();
      case 'connect':
        phase = 'connecting';
        publish();
      case 'disconnect':
        phase = autoStop ? 'disconnected' : 'cleanup';
        publish();
      case 'deviceDisconnect':
        if (music['device'] == target) {
          music = {'phase': 'disconnected', 'device': target, 'selected': ''};
        }
        setConnected(target, false);
      case 'deviceConnect':
        setConnected(target, true);
      case 'musicConnect':
        final failure =
            musicFailure ??
            (target.startsWith('$adapter/')
                ? null
                : 'Choose this device on the selected adapter');
        music = {
          'phase': failure == null ? 'connected' : 'failed',
          'operation': prompt,
          'device': target,
          'selected': 'bluetooth',
          'error': ?failure,
          if (failure == null)
            'source': {'id': 'bluetooth:$target', 'name': 'Fixture music'},
        };
        publish();
      case 'forget':
        if (autoForget) removeDevice(target);
    }
  }
}

class _Projection implements ProjectionService {
  _Projection(this.calls);
  final List<String> calls;
  final events = StreamController<ProjectionSnapshot>.broadcast(sync: true);
  @override
  ProjectionSnapshot current = ProjectionSnapshot(backendAvailable: true);
  @override
  Stream<ProjectionSnapshot> get changes => events.stream;
  void show(
    ProjectionProtocol protocol,
    String address, {
    ProjectionTransport transport = ProjectionTransport.wifi,
    String? deviceId,
    String name = 'Projection fixture',
  }) {
    final device = ProjectionDevice(
      id:
          deviceId ??
          (protocol == ProjectionProtocol.carPlay
              ? carPlayWirelessDeviceId(address)
              : 'wireless-device:fixture'),
      displayName: name,
      protocol: protocol,
      transport: transport,
    );
    current = ProjectionSnapshot(
      backendAvailable: true,
      devices: [device],
      sessions: [
        ProjectionSession(
          id: 'session-${protocol.name}',
          device: device,
          state: ProjectionSessionState.streaming,
        ),
      ],
    );
    events.add(current);
  }

  void clear() {
    current = ProjectionSnapshot(backendAvailable: true);
    events.add(current);
  }

  @override
  Future<void> connect(String deviceId) async {
    calls.add('projection.connect:$deviceId');
  }

  @override
  Future<void> disconnect(String sessionId) async {
    calls.add('projection.disconnect:$sessionId');
    clear();
  }

  @override
  Future<void> close() => events.close();
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected projection operation ${invocation.memberName}',
  );
}

class _CarPlay implements CarPlaySettingsService {
  _CarPlay(this.calls);
  final List<String> calls;
  final events = StreamController<void>.broadcast(sync: true);
  @override
  Stream<void> get changes => events.stream;
  @override
  bool available = true;
  @override
  ServiceFailure? failure;
  @override
  String? error;
  @override
  Map<String, dynamic> current = {
    'running': false,
    'phase': 'Disconnected',
    'target': '',
    'settings': {
      'enabled': true,
      'auto_connect': true,
      'transport': 'wireless',
    },
  };
  bool autoStop = true, failStop = false;
  void Function()? afterStop;
  void publish({bool? running, String? phase, String? target}) {
    current = {
      ...current,
      'running': ?running,
      'phase': ?phase,
      'target': ?target,
    };
    events.add(null);
  }

  @override
  Future<void> refresh() async {}
  @override
  Future<void> configure(Map<String, Object?> settings) async {
    calls.add('cp.configure');
    current = {
      ...current,
      'settings': {...current['settings'] as Map, ...settings},
    };
    events.add(null);
  }

  @override
  Future<void> connect() => connectDevice('');
  @override
  Future<void> connectDevice(String address) async {
    calls.add('cp.connect:$address');
    publish(running: true, phase: 'Waiting for iPhone', target: address);
  }

  @override
  Future<void> disconnect() async {
    calls.add('cp.disconnect');
    if (failStop) {
      failure = const ServiceFailure(
        feature: 'carplay',
        operation: 'disconnect',
        kind: FailureKind.rejected,
        summary: 'Synthetic CarPlay cleanup failure',
        cause: 'fixture',
      );
      return;
    }
    publish(running: false, phase: autoStop ? 'Disconnected' : 'Disconnecting');
    if (autoStop) afterStop?.call();
  }

  @override
  Future<void> close() => events.close();
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected CarPlay operation ${invocation.memberName}');
}

class _Store implements SettingsStore {
  @override
  Future<SettingsDocument> read() async => SettingsDocument();
  @override
  Future<void> write(SettingsDocument document) async {}
}
