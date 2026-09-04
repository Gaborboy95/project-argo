import 'package:argo/core/vehicle/vehicle_signals.dart';
import 'package:argo/integrations/veloce/veloce_vehicle_data_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veloce_lua_core/veloce_lua_core.dart' as veloce;

void main() {
  late veloce.VehicleDataBus bus;
  late VeloceVehicleDataService service;

  setUp(() {
    bus = veloce.VehicleDataBus();
    service = VeloceVehicleDataService(bus);
  });

  tearDown(() => bus.close());

  test('translates current values without maintaining another snapshot', () {
    final timestamp = DateTime.utc(2026, 9, 4, 8, 30);
    bus.publish(
      'engine.rpm',
      3000,
      sourcePluginId: 'dev.example.decoder',
      timestamp: timestamp,
    );

    final point = service.current(VehicleSignals.engineRpm);

    expect(point?.key, 'engine.rpm');
    expect(point?.value, 3000.0);
    expect(point?.timestamp, timestamp);
    expect(point?.sequence, 1);
    expect(point?.sourceId, 'dev.example.decoder');
    expect(service.snapshot['engine.rpm']?.value, 3000);
  });

  test('streams typed signal updates', () async {
    final values = <double>[];
    final subscription = service
        .watch(VehicleSignals.engineRpm)
        .listen((point) => values.add(point.value));

    bus.publish('engine.rpm', 1000);
    await bus.flush();
    bus.publish('engine.rpm', 2000.5);
    await bus.flush();

    expect(values, [1000.0, 2000.5]);
    await subscription.cancel();
  });

  test('emitCurrent delivers the retained bus value', () async {
    bus.publish('engine.rpm', 1500);

    final point = await service
        .watch(VehicleSignals.engineRpm, emitCurrent: true)
        .first;
    await Future<void>.delayed(Duration.zero);

    expect(point.value, 1500.0);
    expect(bus.subscriptionCountFor('argo.vehicle-data.1'), 0);
  });

  test('cancelling a stream removes its Veloce subscription', () async {
    final values = <double>[];
    final subscription = service
        .watch(VehicleSignals.engineRpm)
        .listen((point) => values.add(point.value));
    bus.publish('engine.rpm', 1000);
    await bus.flush();

    await subscription.cancel();
    expect(bus.subscriptionCountFor('argo.vehicle-data.1'), 0);
    bus.publish('engine.rpm', 2000);
    await bus.flush();

    expect(values, [1000.0]);
  });

  test('adapter cancellation does not close the VehicleDataBus', () async {
    final subscription = service.watch(VehicleSignals.engineRpm).listen(null);

    await subscription.cancel();
    final result = bus.publish('engine.rpm', 3000);

    expect(result.subscribers, 0);
    expect(bus.valueFor('engine.rpm')?.value, 3000);
  });
}
