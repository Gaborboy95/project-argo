import 'dart:io';

import 'package:argo/core/vehicle/integration/vehicle_integration_bundle.dart';
import 'package:argo/core/vehicle/integration/vehicle_integration_discovery.dart';
import 'package:argo/core/vehicle/vehicle_signals.dart';
import 'package:argo/integrations/veloce/veloce_vehicle_data_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veloce_lua_core/veloce_lua_core.dart';
import 'package:veloce_lua_native/veloce_lua_native.dart';

void main() {
  test('example integration exposes a valid Veloce decoder bundle', () async {
    final bundle = await _exampleBundle();

    final discovery = await PluginLoader().discover(
      bundle.velocePluginDirectory,
    );

    expect(discovery.failures, isEmpty);
    expect(
      discovery.plugins.map((plugin) => plugin.manifest.id),
      containsAll({
        'dev.example.vehicle.can_decoder',
        'dev.example.vehicle.power_policy',
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

  final nativeLibrary = _configuredNativeLibrary();
  test(
    'example integration drives engine.rpm through real Lua',
    () async {
      final bundle = await _exampleBundle();
      final canProvider = InMemoryCanProvider();
      final manager = PluginManager(
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
      final manager = PluginManager(
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
