import 'dart:io';

import 'package:argo/integrations/simulation/simulation_scenario.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses and orders CAN and vehicle events', () {
    final scenario = SimulationScenario.fromJson({
      'schemaVersion': 1,
      'loop': false,
      'events': [
        {'atMs': 100, 'type': 'vehicle', 'key': 'vehicle.speed', 'value': 50},
        {
          'atMs': 0,
          'type': 'can',
          'bus': 'comfort',
          'id': 640,
          'data': [11, 184],
        },
      ],
    });

    expect(scenario.loop, isFalse);
    expect(scenario.events.map((event) => event.atMs), [0, 100]);
    final canEvent = scenario.events.first as SimulationCanEvent;
    expect(canEvent.frame.bus, 'comfort');
    expect(canEvent.frame.id, 640);
    expect(canEvent.frame.data, [11, 184]);
    final vehicleEvent = scenario.events.last as SimulationVehicleEvent;
    expect(vehicleEvent.key, 'vehicle.speed');
    expect(vehicleEvent.value, 50);
  });

  test('preserves source ordering at identical timestamps', () {
    final scenario = SimulationScenario.fromJson({
      'schemaVersion': 1,
      'events': [
        {'atMs': 10, 'type': 'vehicle', 'key': 'test.order', 'value': 'first'},
        {'atMs': 0, 'type': 'vehicle', 'key': 'test.order', 'value': 'earlier'},
        {'atMs': 10, 'type': 'vehicle', 'key': 'test.order', 'value': 'second'},
      ],
    });

    expect(
      scenario.events.whereType<SimulationVehicleEvent>().map(
        (event) => event.value,
      ),
      ['earlier', 'first', 'second'],
    );
  });

  test('accepts CAN-FD payloads and extended identifiers', () {
    final scenario = SimulationScenario.fromJson({
      'schemaVersion': 1,
      'events': [
        {
          'atMs': 0,
          'type': 'can',
          'bus': 'diagnostic',
          'id': 0x1fffffff,
          'extended': true,
          'data': List<int>.generate(64, (index) => index),
        },
      ],
    });

    final event = scenario.events.single as SimulationCanEvent;
    expect(event.frame.extended, isTrue);
    expect(event.frame.length, 64);
  });

  test('repository CAN decoder scenario is valid', () async {
    final scenario = await SimulationScenario.load(
      File('tool/simulation/veloce_can_decoder.json'),
    );

    final event = scenario.events.single as SimulationCanEvent;
    expect(event.atMs, 500);
    expect(event.frame.bus, 'comfort');
    expect(event.frame.id, 640);
    expect(event.frame.data, [11, 184]);
  });

  test('rejects malformed scenarios and invalid event values', () {
    final invalidScenarios = <Object?>[
      {'schemaVersion': 2, 'events': <Object?>[]},
      {
        'schemaVersion': 1,
        'events': [
          {'atMs': -1, 'type': 'vehicle', 'key': 'vehicle.speed', 'value': 1},
        ],
      },
      {
        'schemaVersion': 1,
        'events': [
          {
            'atMs': 0,
            'type': 'can',
            'bus': 'comfort',
            'id': 0x800,
            'data': <int>[],
          },
        ],
      },
      {
        'schemaVersion': 1,
        'events': [
          {
            'atMs': 0,
            'type': 'can',
            'bus': 'comfort',
            'id': 1,
            'data': List<int>.filled(65, 0),
          },
        ],
      },
      {
        'schemaVersion': 1,
        'events': [
          {'atMs': 0, 'type': 'vehicle', 'key': 'invalid-key', 'value': 1},
        ],
      },
    ];

    for (final source in invalidScenarios) {
      expect(() => SimulationScenario.fromJson(source), throwsFormatException);
    }
    expect(
      () => SimulationScenario.fromJsonString('{not json'),
      throwsFormatException,
    );
  });
}
