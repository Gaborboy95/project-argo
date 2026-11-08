import 'package:argo/core/connectivity/connectivity_service.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> snapshot(
  List<Map<String, Object>> devices, {
  List<Map<String, Object>>? adapters,
}) => {
  'phase': 'idle',
  'detail': 'Ready',
  'adapter': 'hci0',
  'interface': '',
  'selected': '',
  'enabled': false,
  'discovering': false,
  'wifi_connected': false,
  'adapters':
      adapters ??
      [
        {'id': 'hci0', 'name': 'Main', 'address': '00:00:00:00:00:10'},
        {'id': 'hci2', 'name': 'Link', 'address': '00:00:00:00:00:20'},
      ],
  'networks': <Object>[],
  'devices': devices,
};
Map<String, Object> device(
  String id,
  String name, {
  bool paired = false,
  bool connected = false,
}) => {'id': id, 'name': name, 'paired': paired, 'connected': connected};

void main() {
  test('projection microphone uses only fresh exact selected input and never a monitor fallback', () {
    String? selection(Map<String, dynamic> voice, {String phase = 'idle'}) {
      final json = snapshot([])
        ..['voice'] = voice
        ..['phase'] = phase;
      return ConnectivitySnapshot.fromJson(json).selectedProjectionMicrophone;
    }

    final available = <String, dynamic>{
      'inventory_available': true,
      'selected': 'usb.adc',
      'inputs': [
        {'id': 'usb.adc', 'name': 'USB microphone'},
      ],
    };
    expect(selection(available), 'usb.adc');
    // Microphone availability is independent of wireless/adapter availability.
    expect(selection(available, phase: 'unavailable'), 'usb.adc');
    expect(selection({...available, 'inventory_available': false}), isNull);
    expect(selection({...available}..remove('inventory_available')), isNull);
    expect(selection({...available, 'inputs': null}), isNull);
    expect(selection({...available, 'selected': ''}), '');
    expect(selection({...available, 'selected': 'remembered.but.missing'}), '');
    expect(selection({...available, 'inputs': <Object>[]}), '');
    expect(
      selection({
        'inventory_available': true,
        'selected': 'speaker.monitor',
        'inputs': [
          {'id': 'speaker.monitor', 'name': 'Speaker monitor'},
        ],
      }),
      '',
    );
    const disconnected = ConnectivitySnapshot(
      voice: {
        'inventory_available': true,
        'selected': 'usb.adc',
        'inputs': [
          {'id': 'usb.adc'},
        ],
      },
    );
    expect(disconnected.selectedProjectionMicrophone, isNull);
  });

  test('projection microphone preserves a remembered choice through probe loss and replug', () {
    ConnectivitySnapshot state(
      bool available,
      List<Map<String, String>> inputs,
    ) => ConnectivitySnapshot.fromJson(
      snapshot([])
        ..['voice'] = {
          'inventory_available': available,
          'selected': 'usb.adc',
          'inputs': inputs,
        },
    );
    final source = [
      {'id': 'usb.adc', 'name': 'USB microphone'},
    ];
    expect(state(true, source).selectedProjectionMicrophone, 'usb.adc');
    expect(state(false, source).selectedProjectionMicrophone, isNull);
    final unplugged = state(true, []);
    expect(unplugged.selectedProjectionMicrophone, '');
    expect(unplugged.voice!['selected'], 'usb.adc');
    expect(state(true, source).selectedProjectionMicrophone, 'usb.adc');
  });

  test('selected, prompt, audio and call references share normalized endpoint identity', () {
    final json = snapshot([
      device('hci0/aa:bb:00:00:00:01', 'Phone', paired: true),
    ]);
    json['selected'] = 'hci0/aa:bb:00:00:00:01';
    json['prompt'] = {
      'id': 1,
      'device': 'hci0/aa:bb:00:00:00:01',
      'name': 'Phone',
      'text': 'Approve',
    };
    json['music'] = {'device': 'hci0/aa:bb:00:00:00:01'};
    json['calls'] = {'device': 'hci0/aa:bb:00:00:00:01'};
    final state = ConnectivitySnapshot.fromJson(json);
    final id = state.devices.single.id;
    expect(id, 'hci0/AA:BB:00:00:00:01');
    expect([
      state.selected,
      state.prompt!.device,
      state.music!['device'],
      state.calls!['device'],
    ], everyElement(id));
  });

  test('normalizes duplicate routes and groups the same address without merging aliases', () {
    final devices = [
      device('hci2/AA:00:00:00:00:01', 'My phone', paired: true),
      device('hci0/aa:00:00:00:00:01', 'AA:00:00:00:00:01', connected: true),
      device('hci0/AA:00:00:00:00:01', 'My phone', paired: true),
      device('hci0/BB:00:00:00:00:01', 'My phone', paired: true),
    ];
    final first = ConnectivitySnapshot.fromJson(snapshot(devices));
    final reversed = ConnectivitySnapshot.fromJson(
      snapshot(devices.reversed.toList()),
    );
    expect(
      first.devices.map((d) => (d.id, d.name, d.paired, d.connected)),
      reversed.devices.map((d) => (d.id, d.name, d.paired, d.connected)),
    );
    expect(first.devices, hasLength(3));
    expect(first.deviceGroups, hasLength(2));
    final phone = first.deviceGroups.first;
    expect(phone.name, 'My phone');
    expect(phone.endpoints, hasLength(2));
    expect(phone.paired && phone.connected, isTrue);
    expect(phone.forAdapter('hci0')!.id, 'hci0/AA:00:00:00:00:01');
    expect(phone.forAdapter('hci2')!.id, 'hci2/AA:00:00:00:00:01');
    expect(phone.forAdapter('hci9'), isNull);
  });

  test('phone identity and relative order survive radio renumbering, aliases and status changes', () {
    final old = ConnectivitySnapshot.fromJson(
      snapshot([
        device('hci0/BB:00:00:00:00:01', 'A phone', paired: true),
        device('hci0/AA:00:00:00:00:01', 'Z phone'),
      ]),
    );
    final next = ConnectivitySnapshot.fromJson(
      snapshot(
        [
          device(
            'hci9/AA:00:00:00:00:01',
            'A new alias',
            paired: true,
            connected: true,
          ),
          device('hci9/BB:00:00:00:00:01', 'Z new alias'),
        ],
        adapters: [
          {
            'id': 'hci9',
            'name': 'Renamed radio',
            'address': '00:00:00:00:00:10',
          },
        ],
      ),
    );
    expect(
      next.deviceGroups.map((d) => d.id),
      old.deviceGroups.map((d) => d.id),
    );
    expect(
      next.deviceGroups.first.forAdapter('hci9')!.id,
      'hci9/AA:00:00:00:00:01',
    );
    expect(next.deviceGroups.first.forAdapter('hci0'), isNull);
  });

  test('radio inventories sort by hardware identity and retain distinct opaque devices', () {
    final state = ConnectivitySnapshot.fromJson(
      snapshot(
        [
          device('hci0/opaque-a', 'Phone', paired: true),
          device('hci2/opaque-b', 'Phone', paired: true),
        ],
        adapters: [
          {'id': 'hci7', 'name': 'A', 'address': '00:00:00:00:00:20'},
          {'id': 'hci9', 'name': 'Z', 'address': '00:00:00:00:00:10'},
        ],
      ),
    );
    expect(state.adapters.map((r) => r.id), ['hci9', 'hci7']);
    expect(state.deviceGroups, hasLength(2));
    expect(
      () => state.devices.add(const ConnectivityDevice('x', 'x', false, false)),
      throwsUnsupportedError,
    );
  });
}
