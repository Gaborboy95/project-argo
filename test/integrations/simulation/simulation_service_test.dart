import 'dart:async';
import 'dart:io';

import 'package:argo/core/power/head_unit_operational_state.dart';
import 'package:argo/core/power/vehicle_data_head_unit_power_service.dart';
import 'package:argo/core/vehicle/vehicle_ignition_state.dart';
import 'package:argo/core/vehicle/vehicle_power_state.dart';
import 'package:argo/integrations/simulation/simulation_scenario.dart';
import 'package:argo/integrations/simulation/simulation_service.dart';
import 'package:argo/integrations/veloce/veloce_vehicle_data_service.dart';
import 'package:veloce_lua_core/veloce_lua_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late InMemoryCanProvider canProvider;
  late VehicleDataBus vehicleDataBus;
  late SimulationService simulation;

  setUp(() {
    canProvider = InMemoryCanProvider();
    vehicleDataBus = VehicleDataBus();
    simulation = SimulationService(
      canProvider: canProvider,
      vehicleDataBus: vehicleDataBus,
    );
  });

  tearDown(() async {
    await simulation.stopScenario();
    await canProvider.close();
    await vehicleDataBus.close();
  });

  test('injects scenario CAN through normal provider filtering', () async {
    final received = <CanFrame>[];
    await canProvider.subscribe(
      ownerId: 'test.decoder',
      filter: CanFilter(bus: 'comfort', id: 640),
      onFrame: received.add,
    );
    final scenario = SimulationScenario(
      loop: false,
      events: [
        SimulationCanEvent(
          atMs: 0,
          frame: CanFrame(bus: 'powertrain', id: 640, data: const [1]),
        ),
        SimulationCanEvent(
          atMs: 0,
          frame: CanFrame(bus: 'comfort', id: 640, data: const [11, 184]),
        ),
      ],
    );

    await simulation.startScenario(scenario);
    await simulation.scenarioCompletion;
    await canProvider.flush();

    expect(received, hasLength(1));
    expect(received.single.data, [11, 184]);
  });

  test('publishes scenario vehicle data with the simulation owner', () async {
    final scenario = SimulationScenario(
      loop: false,
      events: [
        SimulationVehicleEvent(atMs: 0, key: 'vehicle.speed', value: 50),
      ],
    );

    await simulation.startScenario(scenario);
    await simulation.scenarioCompletion;

    final point = vehicleDataBus.valueFor('vehicle.speed');
    expect(point?.value, 50);
    expect(point?.sourcePluginId, SimulationService.sourceOwnerId);
  });

  test(
    'programmatic injection and publication use the same boundaries',
    () async {
      final frames = <CanFrame>[];
      await canProvider.subscribe(
        ownerId: 'test.decoder',
        filter: CanFilter(bus: 'comfort', id: 1),
        onFrame: frames.add,
      );

      final injection = simulation.injectCanFrame(
        CanFrame(bus: 'comfort', id: 1, data: const [2]),
      );
      simulation.publishVehicleValue('test.signal', true);
      await canProvider.flush();

      expect(injection.matchedSubscriptions, 1);
      expect(frames, hasLength(1));
      expect(vehicleDataBus.valueFor('test.signal')?.value, isTrue);
    },
  );

  test('stop cancels playback and restart plays from the beginning', () async {
    final scenario = SimulationScenario(
      loop: false,
      events: [
        SimulationVehicleEvent(atMs: 30, key: 'test.restart', value: 'played'),
      ],
    );

    await simulation.startScenario(scenario);
    expect(simulation.isScenarioRunning, isTrue);
    await simulation.stopScenario();
    expect(simulation.isScenarioRunning, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 45));
    expect(vehicleDataBus.valueFor('test.restart'), isNull);

    await simulation.restartScenario();
    expect(simulation.isScenarioRunning, isTrue);
    await simulation.scenarioCompletion;

    expect(vehicleDataBus.valueFor('test.restart')?.value, 'played');
    expect(simulation.isScenarioRunning, isFalse);
  });

  test('looping repeats until stopped', () async {
    final repeated = Completer<void>();
    var updates = 0;
    vehicleDataBus.subscribe(
      ownerId: 'test.observer',
      key: 'test.loop',
      handler: (point) {
        updates++;
        if (updates >= 3 && !repeated.isCompleted) repeated.complete();
      },
    );
    final scenario = SimulationScenario(
      loop: true,
      events: [SimulationVehicleEvent(atMs: 1, key: 'test.loop', value: 1)],
    );

    await simulation.startScenario(scenario);
    await repeated.future.timeout(const Duration(seconds: 1));
    expect(simulation.isScenarioRunning, isTrue);
    await simulation.stopScenario();
    final updatesAfterStop = updates;
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(simulation.isScenarioRunning, isFalse);
    expect(updates, updatesAfterStop);
  });

  test('repository scenario drives normalized head-unit power state', () async {
    final power = VehicleDataHeadUnitPowerService(
      vehicleData: VeloceVehicleDataService(vehicleDataBus),
    );
    try {
      final scenario = await SimulationScenario.load(
        File('tool/simulation/power_state_cycle.json'),
      );

      await simulation.startScenario(scenario);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await vehicleDataBus.flush();

      expect(power.current.vehiclePowerState, VehiclePowerState.asleep);
      expect(power.current.ignitionState, VehicleIgnitionState.off);
      expect(power.current.batteryVoltage, 12.4);
      expect(power.current.operationalState, HeadUnitOperationalState.standby);
    } finally {
      await simulation.stopScenario();
      await power.close();
    }
  });
}
