import 'package:argo/integrations/veloce/argo_host_state_bridge.dart';

import 'dart:io';

import 'package:argo/core/vehicle/integration/vehicle_integration_bundle.dart';
import 'package:argo/core/vehicle/integration/vehicle_integration_discovery.dart';
import 'package:argo/core/vehicle/vehicle_signals.dart';
import 'package:argo/core/vehicle/vehicle_power_state.dart';
import 'package:argo/integrations/veloce/veloce_vehicle_data_service.dart';
import 'package:argo/integrations/veloce/restartable_can_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veloce_lua_core/veloce_lua_core.dart';
import 'package:veloce_lua_native/veloce_lua_native.dart';

void main() {
  test('example integration exposes a valid Veloce decoder bundle', () async {
    final bundle = await _exampleBundle();

    final discovery = await ArgoHostStateBridge.loader().discover(
      bundle.velocePluginDirectory,
    );

    expect(discovery.failures, isEmpty);
    expect(
      discovery.plugins.map((plugin) => plugin.manifest.id),
      containsAll({
        'dev.example.vehicle.can_decoder',
        'dev.example.vehicle.battery_protection',
        'dev.example.vehicle.power_policy',
        'dev.example.vehicle.audio_policy',
      }),
    );
    final decoder = discovery.plugins.singleWhere(
      (plugin) => plugin.manifest.id == 'dev.example.vehicle.can_decoder',
    );
    final filter = decoder.manifest.canAccess.readFilters.single;
    expect(
      filter.matches(CanFrame(bus: 'comfort', id: 640, data: const [11, 184])),
      isTrue,
    );
  });

  test(
    'example audio policy is normalized and transport-independent',
    () async {
      final bundle = await _exampleBundle();
      final source = await File.fromUri(
        bundle.velocePluginDirectory.uri.resolve('audio_policy/main.lua'),
      ).readAsString();

      expect(source, contains('controls.audio.volume_up.pressed'));
      expect(source, contains('audio.command.volume.up'));
      expect(source, isNot(contains('veloce.can')));
      expect(source, isNot(contains('can.subscribe')));
      expect(source, isNot(contains('can.send')));
    },
  );

  final nativeLibrary = _configuredNativeLibrary();
  test(
    'example Lua audio policy emits once per normalized rising edge',
    () async {
      final bundle = await _exampleBundle();
      final manager = _hostManager(
        pluginRoot: bundle.velocePluginDirectory,
        runtimeFactory: IsolatedNativeLuaRuntimeFactory(
          libraryPath: nativeLibrary,
        ),
      );
      final commands = <String, List<PluginEvent>>{
        'audio.command.volume.up': [],
        'audio.command.volume.down': [],
        'audio.command.mute.toggle': [],
        'audio.command.source.next': [],
        'audio.command.source.previous': [],
      };
      final subscriptions = [
        for (final entry in commands.entries)
          manager.eventBus.subscribe(
            ownerId: 'argo.test.audio',
            topic: entry.key,
            handler: entry.value.add,
          ),
      ];
      addTearDown(() async {
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
        await manager.close();
      });
      final discovery = await manager.discover();
      expect(discovery.failures, isEmpty);

      void press(String signal) {
        manager.vehicleDataBus.publish(signal, false);
        manager.vehicleDataBus.publish(signal, true);
      }

      press('controls.audio.volume_up.pressed');
      manager.vehicleDataBus.publish('controls.audio.volume_up.pressed', true);
      press('controls.audio.volume_down.pressed');
      press('controls.audio.mute.pressed');
      press('controls.audio.source_next.pressed');
      press('controls.audio.source_previous.pressed');
      await manager.vehicleDataBus.flush();
      await manager.eventBus.flush();
      expect(commands.values, everyElement(hasLength(1)));

      press('controls.audio.volume_up.pressed');
      await manager.vehicleDataBus.flush();
      await manager.eventBus.flush();
      expect(commands['audio.command.volume.up'], hasLength(2));
      expect(
        commands.values
            .expand((events) => events)
            .every(
              (command) =>
                  command.sourcePluginId == 'dev.example.vehicle.audio_policy',
            ),
        isTrue,
      );
    },
    skip: nativeLibrary == null
        ? 'Set VELOCE_LUA_LIBRARY to run the real Lua integration test.'
        : false,
  );

  test(
    'example integration drives engine.rpm through real Lua',
    () async {
      final bundle = await _exampleBundle();
      final canProvider = InMemoryCanProvider();
      final manager = _hostManager(
        pluginRoot: bundle.velocePluginDirectory,
        runtimeFactory: IsolatedNativeLuaRuntimeFactory(
          libraryPath: nativeLibrary,
        ),
        canProvider: canProvider,
      );
      addTearDown(() async {
        await manager.close();
        await canProvider.close();
      });

      final discovery = await manager.discover();
      expect(discovery.failures, isEmpty);
      expect(
        manager.currentPlugins,
        everyElement(
          isA<PluginRecord>().having(
            (plugin) => plugin.state,
            'state',
            PluginState.running,
          ),
        ),
      );

      final result = canProvider.inject(
        CanFrame(bus: 'comfort', id: 640, data: const [11, 184]),
      );
      expect(result.matchedSubscriptions, 1);
      await canProvider.flush();
      await manager.vehicleDataBus.flush();

      final vehicleData = VeloceVehicleDataService(manager.vehicleDataBus);
      expect(vehicleData.current(VehicleSignals.engineRpm)?.value, 3000.0);

      canProvider.inject(CanFrame(bus: 'comfort', id: 0x500, data: const [2]));
      canProvider.inject(
        CanFrame(bus: 'comfort', id: 0x501, data: const [44, 136]),
      );
      await canProvider.flush();
      await manager.vehicleDataBus.flush();
      expect(
        vehicleData.current(VehicleSignals.vehiclePowerState)?.value,
        VehiclePowerState.awake,
      );
      expect(
        vehicleData.current(VehicleSignals.vehicleBatteryVoltage)?.value,
        11.4,
      );
    },
    skip: nativeLibrary == null
        ? 'Set VELOCE_LUA_LIBRARY to run the real Lua integration test.'
        : false,
  );

  test(
    'transport recreation preserves Veloce generations and logical CAN '
    'subscriptions',
    () async {
      final bundle = await _exampleBundle();
      final delegates = <InMemoryCanProvider>[];
      final canProvider = await RestartableCanProvider.start(
        delegateFactory: () async {
          final delegate = InMemoryCanProvider();
          delegates.add(delegate);
          return delegate;
        },
        writesEnabled: false,
      );
      final manager = _hostManager(
        pluginRoot: bundle.velocePluginDirectory,
        runtimeFactory: IsolatedNativeLuaRuntimeFactory(
          libraryPath: nativeLibrary,
        ),
        canProvider: canProvider,
      );
      addTearDown(() async {
        await manager.close();
        await canProvider.close();
      });
      await manager.discover();
      final generations = {
        for (final plugin in manager.currentPlugins)
          plugin.manifest.id: plugin.generation,
      };

      delegates.single.inject(
        CanFrame(bus: 'comfort', id: 0x280, data: const [11, 184]),
      );
      await delegates.single.flush();
      await manager.vehicleDataBus.flush();
      await canProvider.quiesce();
      await canProvider.resume();

      expect({
        for (final plugin in manager.currentPlugins)
          plugin.manifest.id: plugin.generation,
      }, generations);
      delegates.last.inject(
        CanFrame(bus: 'comfort', id: 0x280, data: const [13, 172]),
      );
      await delegates.last.flush();
      await manager.vehicleDataBus.flush();
      expect(
        VeloceVehicleDataService(manager.vehicleDataBus)
            .current(VehicleSignals.engineRpm)
            ?.value,
        3500,
      );
    },
    skip: nativeLibrary == null
        ? 'Set VELOCE_LUA_LIBRARY to run the real Lua integration test.'
        : false,
  );

  test(
    'example Lua power policy cancels wakeups and publishes once per sleep '
    'episode',
    () async {
      final bundle = await _exampleBundle();
      final manager = _hostManager(
        pluginRoot: bundle.velocePluginDirectory,
        runtimeFactory: IsolatedNativeLuaRuntimeFactory(
          libraryPath: nativeLibrary,
        ),
      );
      final requests = <PluginEvent>[];
      final subscription = manager.eventBus.subscribe(
        ownerId: 'argo.test.host-power',
        topic: 'host.power.suspend.request',
        handler: requests.add,
      );
      addTearDown(() async {
        await subscription.cancel();
        await manager.close();
      });

      final discovery = await manager.discover();
      expect(discovery.failures, isEmpty);
      expect(
        manager.currentPlugins
            .singleWhere(
              (plugin) =>
                  plugin.manifest.id == 'dev.example.vehicle.power_policy',
            )
            .state,
        PluginState.running,
      );

      manager.vehicleDataBus.publish('vehicle.power.state', 'asleep');
      await manager.vehicleDataBus.flush();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      manager.vehicleDataBus.publish('vehicle.power.state', 'awake');
      await manager.vehicleDataBus.flush();
      await Future<void>.delayed(const Duration(milliseconds: 1550));
      await manager.eventBus.flush();
      expect(requests, isEmpty);

      manager.vehicleDataBus.publish('vehicle.power.state', 'asleep');
      await manager.vehicleDataBus.flush();
      await Future<void>.delayed(const Duration(milliseconds: 1550));
      await manager.eventBus.flush();
      expect(requests, hasLength(1));
      expect(
        requests.single.sourcePluginId,
        'dev.example.vehicle.power_policy',
      );
      expect(requests.single.data, {'reason': 'vehicle_standby'});

      await Future<void>.delayed(const Duration(milliseconds: 100));
      await manager.eventBus.flush();
      expect(requests, hasLength(1));

      manager.vehicleDataBus.publish('vehicle.power.state', 'awake');
      manager.vehicleDataBus.publish('vehicle.power.state', 'asleep');
      await manager.vehicleDataBus.flush();
      await Future<void>.delayed(const Duration(milliseconds: 1550));
      await manager.eventBus.flush();
      expect(requests, hasLength(2));
    },
    skip: nativeLibrary == null
        ? 'Set VELOCE_LUA_LIBRARY to run the real Lua integration test.'
        : false,
  );

  test(
    'example Lua battery policy confirms, hysteretically rearms, and '
    'publishes once per low-voltage episode',
    () async {
      final bundle = await _exampleBundle();
      final manager = _hostManager(
        pluginRoot: bundle.velocePluginDirectory,
        runtimeFactory: IsolatedNativeLuaRuntimeFactory(
          libraryPath: nativeLibrary,
        ),
      );
      final requests = <PluginEvent>[];
      final subscription = manager.eventBus.subscribe(
        ownerId: 'argo.test.host-power',
        topic: 'host.power.shutdown.request',
        handler: requests.add,
      );
      addTearDown(() async {
        await subscription.cancel();
        await manager.close();
      });

      final discovery = await manager.discover();
      expect(discovery.failures, isEmpty);
      expect(
        manager.currentPlugins
            .singleWhere(
              (plugin) =>
                  plugin.manifest.id ==
                  'dev.example.vehicle.battery_protection',
            )
            .state,
        PluginState.running,
      );

      manager.vehicleDataBus.publish('vehicle.battery.voltage', 11.4);
      await manager.vehicleDataBus.flush();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      manager.vehicleDataBus.publish('vehicle.battery.voltage', 12.1);
      await manager.vehicleDataBus.flush();
      await _waitPastBatteryConfirmation(manager);
      expect(requests, isEmpty);

      manager.vehicleDataBus.publish('vehicle.battery.voltage', 11.4);
      await manager.vehicleDataBus.flush();
      await _waitPastBatteryConfirmation(manager);
      expect(requests, hasLength(1));
      expect(
        requests.single.sourcePluginId,
        'dev.example.vehicle.battery_protection',
      );
      expect(requests.single.data, {'reason': 'low_battery'});

      for (final voltage in const [11.3, 11.8, 11.2]) {
        manager.vehicleDataBus.publish('vehicle.battery.voltage', voltage);
      }
      await manager.vehicleDataBus.flush();
      await _waitPastBatteryConfirmation(manager);
      expect(requests, hasLength(1));

      manager.vehicleDataBus.publish('vehicle.battery.voltage', 12.1);
      await manager.vehicleDataBus.flush();
      manager.vehicleDataBus.publish('vehicle.battery.voltage', 11.4);
      await manager.vehicleDataBus.flush();
      await _waitPastBatteryConfirmation(manager);
      expect(requests, hasLength(2));
    },
    skip: nativeLibrary == null
        ? 'Set VELOCE_LUA_LIBRARY to run the real Lua integration test.'
        : false,
  );
}

Future<void> _waitPastBatteryConfirmation(PluginManager manager) async {
  await Future<void>.delayed(const Duration(milliseconds: 2150));
  await manager.eventBus.flush();
}

Future<VehicleIntegrationBundle> _exampleBundle() async {
  final result = await const VehicleIntegrationDiscovery().discover(
    Directory('tool/vehicle_integrations').absolute,
  );
  expect(result.failures, isEmpty);
  return result.bundles.single;
}

String? _configuredNativeLibrary() {
  final configured = Platform.environment['VELOCE_LUA_LIBRARY']?.trim();
  if (configured == null || configured.isEmpty) return null;
  final library = File(configured);
  return library.existsSync() ? library.absolute.path : null;
}

PluginManager _hostManager({
  required Directory pluginRoot,
  required PluginScriptRuntimeFactory runtimeFactory,
  CanProvider? canProvider,
}) {
  final manager = PluginManager(
    pluginRoot: pluginRoot,
    runtimeFactory: runtimeFactory,
    canProvider: canProvider,
    capabilityManager: ArgoHostStateBridge.capabilityManager(),
    loader: ArgoHostStateBridge.loader(),
  );
  final bridge = ArgoHostStateBridge()..register(manager);
  addTearDown(bridge.close);
  return manager;
}
