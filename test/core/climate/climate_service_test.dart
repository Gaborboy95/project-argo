import 'dart:async';

import 'package:argo/core/climate/climate_service.dart';
import 'package:argo/core/diagnostics/diagnostics_service.dart';
import 'package:argo/core/vehicle/integration/vehicle_integration_manifest.dart';
import 'package:argo/integrations/veloce/veloce_vehicle_data_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veloce_lua_core/veloce_lua_core.dart' as v;

class Clock {
  int now = 0;
  final List<Alarm> alarms = [];
  Timer timer(Duration d, void Function() f) {
    final a = Alarm(now + d.inMilliseconds, f);
    alarms.add(a);
    return a;
  }

  void advance(int milliseconds) {
    now += milliseconds;
    for (final a in List.of(alarms)) {
      if (a.isActive && a.at <= now) {
        a.cancel();
        a.callback();
      }
    }
  }
}

class Alarm implements Timer {
  Alarm(this.at, this.callback);
  final int at;
  final void Function() callback;
  @override
  bool isActive = true;
  @override
  int get tick => isActive ? 0 : 1;
  @override
  void cancel() => isActive = false;
}

void main() {
  test(
    'schema 1 remains compatible and validates bounded climate metadata',
    () {
      const parser = VehicleIntegrationManifestParser();
      final manifest = <String, Object?>{
        'schemaVersion': 1,
        'id': 'example.car',
        'displayName': 'Example',
        'capabilities': ['climate.control'],
      };
      expect(parser.parse(manifest).climate, isNull);
      final metadata = {
        'zones': {
          'front_left': {'minC': 18, 'maxC': 26, 'stepC': .5},
        },
        'fan': {'min': 0, 'max': 5, 'step': 1},
        'features': ['ac'],
      };
      expect(
        parser
            .parse({...manifest, 'climate': metadata})
            .climate!
            .zones['front_left']!
            .stepC,
        .5,
      );
      for (final bad in [
        {
          ...metadata,
          'features': ['seats'],
        },
        {
          ...metadata,
          'zones': {
            'bad.zone': {'minC': 18, 'maxC': 26, 'stepC': .5},
          },
        },
        for (final range in [
          {'minC': 26, 'maxC': 18, 'stepC': .5},
          {'minC': 18, 'maxC': 26, 'stepC': 0},
          {'minC': double.nan, 'maxC': 26, 'stepC': .5},
        ])
          {
            ...metadata,
            'zones': {'front_left': range},
          },
      ]) {
        expect(
          () => parser.parse({...manifest, 'climate': bad}),
          throwsFormatException,
        );
      }
    },
  );

  test('pending feedback, timeout, coalescing final value and invalidation use real vehicle bus', () async {
    final bus = v.VehicleDataBus(),
        clock = Clock(),
        diagnostics = DiagnosticsService();
    final commands = <Map<String, Object>>[];
    final service = VehicleClimateService(
      capabilities: ClimateCapabilities.simulation(),
      vehicle: VeloceVehicleDataService(bus),
      publish: (p) async {
        commands.add(p);
      },
      authorize: (id) async => id == 'selected',
      diagnostics: diagnostics,
      timer: clock.timer,
    );
    service.invalidate(available: true);
    const key = 'climate.front_left.target_temperature_c';
    ClimateValue<double> value() => service.current.temperatures['front_left']!;
    Future<void> feedback(Object data, {String source = 'selected'}) async {
      bus.publish(key, data, sourcePluginId: source);
      await bus.flush();
      await Future<void>.delayed(Duration.zero);
    }

    expect(value().confirmed, isNull);
    service.requestTemperature('front_left', 22, immediate: true);
    expect(value().requested, 22);
    expect(value().pending, isTrue);
    expect(value().confirmed, isNull);
    await feedback(22, source: 'outside');
    await feedback(99);
    await feedback('22');
    expect(value().confirmed, isNull);
    expect(diagnostics.snapshot.length, 1);
    await feedback(22);
    expect(value().confirmed, 22);
    expect(value().pending, isFalse);
    for (final t in [22.5, 23.0, 23.5]) {
      service.requestTemperature('front_left', t);
      clock.advance(30);
    }
    expect(commands.length, 1);
    expect(value().displayed, 23.5);
    clock.advance(100);
    await Future<void>.delayed(Duration.zero);
    expect(commands.length, 2);
    expect(commands.last, {
      'operation': 'set_temperature',
      'zone': 'front_left',
      'valueC': 23.5,
    });
    clock.advance(3000);
    expect(value().pending, isFalse);
    expect(value().confirmed, 22);
    expect(value().displayed, 22);
    expect(value().failure, isNotNull);
    await feedback(23.5);
    expect(value().confirmed, 23.5);
    expect(value().failure, isNull);
    service.requestTemperature('front_left', 24, immediate: true);
    await feedback(24);
    expect(value().failure, isNull);
    expect(value().confirmed, 24);
    service.requestFanLevel(3);
    service.requestAc(true);
    expect(service.current.fan.pending, isTrue);
    expect(service.current.ac.confirmed, isNull);
    bus.publish('climate.fan.level', 3, sourcePluginId: 'selected');
    bus.publish('climate.ac.enabled', true, sourcePluginId: 'selected');
    await bus.flush();
    await Future<void>.delayed(Duration.zero);
    expect(service.current.fan.confirmed, 3);
    expect(service.current.ac.confirmed, isTrue);
    expect(commands.last, {'operation': 'set_ac', 'value': true});
    expect(
      () => service.requestTemperature('front_left', 22.1),
      throwsArgumentError,
    );
    service.requestTemperature('front_left', 25);
    service.invalidate();
    clock.advance(4000);
    expect(value().confirmed, isNull);
    expect(value().pending, isFalse);
    expect(service.current.available, isFalse);
    final count = commands.length;
    await service.close();
    clock.advance(4000);
    await feedback(22);
    expect(commands.length, count);
    await bus.close();
  });
}
