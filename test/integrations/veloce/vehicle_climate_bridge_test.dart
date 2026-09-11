import 'dart:io';

import 'package:argo/core/climate/climate_service.dart';
import 'package:argo/core/diagnostics/diagnostics_service.dart';
import 'package:argo/integrations/veloce/vehicle_climate_bridge.dart';
import 'package:argo/integrations/veloce/veloce_vehicle_data_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veloce_lua_core/veloce_lua_core.dart';

void main() {
  test('selected bundle provenance, command topic and plugin replacement invalidate climate', () async {
    final root = await Directory.systemTemp.createTemp('argo-climate-');
    final selected = await Directory('${root.path}/selected/plugin')
        .create(recursive: true);
    final outside = await Directory('${root.path}/other/plugin')
        .create(recursive: true);
    final registry = PluginRegistry(),
        events = PluginEventBus(),
        data = VehicleDataBus();
    final diagnostics = DiagnosticsService();
    PluginRecord record(String id, Directory directory, String generation) =>
        PluginRecord(
          directoryPath: directory.path,
          manifest: PluginManifest(
            id: id,
            name: id,
            version: const SemanticVersion(major: 1, minor: 0, patch: 0),
            apiVersion: '1',
            entrypoint: 'main.lua',
            permissions: const [],
          ),
          state: PluginState.running,
          enabled: true,
          generation: generation,
        );
    registry.put(record('selected', selected, 'one'));
    registry.put(record('outside', outside, 'one'));
    final bridge = await VehicleClimateBridge.start(
      registry: registry,
      events: events,
      isLoaded: (_) => true,
      root: selected.parent,
      capabilities: ClimateCapabilities.simulation(),
      vehicle: VeloceVehicleDataService(data),
      diagnostics: diagnostics,
    );
    // Wait for the initial registry stream's asynchronous canonical-path checks.
    for (var i = 0; i < 100 && !bridge.service.current.available; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(bridge.service.current.available, isTrue);
    final requests = <Object?>[];
    final sub = events.subscribe(
      ownerId: 'selected',
      topic: VehicleClimateService.requestTopic,
      handler: (e) => requests.add(e.data),
    );
    Future<void> feedback(String source, double value) async {
      data.publish(
        'climate.front_left.target_temperature_c',
        value,
        sourcePluginId: source,
      );
      await data.flush();
      // Authorizer performs real filesystem checks, independently of the bus handler.
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
    }

    await feedback('outside', 21);
    expect(
      bridge.service.current.temperatures['front_left']!.confirmed,
      isNull,
    );
    bridge.service.requestTemperature('front_left', 22, immediate: true);
    for (var i = 0; i < 100 && requests.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await events.flush();
    expect(requests, [
      {'operation': 'set_temperature', 'zone': 'front_left', 'valueC': 22.0},
    ]);
    await feedback('selected', 22);
    expect(bridge.service.current.temperatures['front_left']!.confirmed, 22);
    bridge.service.requestTemperature('front_left', 23);
    registry.remove('selected');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(bridge.service.current.available, isFalse);
    expect(
      bridge.service.current.temperatures['front_left']!.confirmed,
      isNull,
    );
    expect(requests.length, 1);
    registry.put(record('selected', selected, 'two'));
    for (var i = 0; i < 100 && !bridge.service.current.available; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(
      bridge.service.current.temperatures['front_left']!.confirmed,
      isNull,
    ); // cached old bus state is not replayed
    await bridge.close();
    await sub.cancel();
    await events.close();
    await data.close();
    await registry.close();

    await root.delete(recursive: true);
  });
}
