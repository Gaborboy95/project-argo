import 'dart:async';
import 'dart:io';

import 'package:veloce_lua_core/veloce_lua_core.dart';

import '../../core/climate/climate_service.dart';
import '../../core/diagnostics/diagnostics_service.dart';
import '../../core/vehicle/vehicle_data_service.dart';
import 'vehicle_integration_plugin_authorizer.dart';

/// The selected bundle is fixed at bootstrap. Replacement closes this bridge;
/// plugin reload/unload within that bundle invalidates all live climate state.
class VehicleClimateBridge {
  VehicleClimateBridge._(this.registry, this.authorizer);
  final PluginRegistry registry;
  final VehicleIntegrationPluginAuthorizer authorizer;
  late final VehicleClimateService service;
  Map<String, PluginRecord> _members = {};
  StreamSubscription<List<PluginRecord>>? _subscription;
  int _revision = 0;
  bool _closed = false;
  static Future<VehicleClimateBridge> start({
    required PluginRegistry registry,
    required PluginEventBus events,
    required VelocePluginLoadedLookup isLoaded,
    required Directory? root,
    required ClimateCapabilities? capabilities,
    required VehicleDataService vehicle,
    required DiagnosticsService diagnostics,
  }) async {
    final bridge = VehicleClimateBridge._(
      registry,
      await VehicleIntegrationPluginAuthorizer.create(
        pluginRegistry: registry,
        isPluginLoaded: isLoaded,
        activeIntegrationPluginRoot: root,
        diagnostics: diagnostics,
      ),
    );
    bridge.service = VehicleClimateService(
      capabilities: capabilities,
      vehicle: vehicle,
      diagnostics: diagnostics,
      authorize: bridge.authorizer.allows,
      publish: (payload) async {
        final revision = bridge._revision;
        var allowed = false;
        for (final entry in bridge._members.entries) {
          if (identical(registry[entry.key], entry.value) &&
              await bridge.authorizer.allows(entry.key)) {
            allowed = true;
          }
        }
        if (!allowed || bridge._closed || revision != bridge._revision) {
          throw StateError('Selected integration unavailable');
        }
        final state = bridge.service.current;
        final value = switch (payload['operation']) {
          'set_temperature' => state.temperatures[payload['zone']],
          'set_fan_level' => state.fan,
          _ => state.ac,
        };
        if (!state.available ||
            value?.pending != true ||
            value?.requested != (payload['valueC'] ?? payload['value'])) {
          return;
        }
        final result = events.publish(
          VehicleClimateService.requestTopic,
          payload,
        );
        if (result.enqueuedDeliveries == 0 || result.droppedDeliveries > 0) {
          throw StateError('Climate request not delivered');
        }
      },
    );
    bridge._subscription = registry.records.listen((_) {
      // Revoke immediately before asynchronous path validation.
      if (bridge._members.entries.any(
        (e) => !identical(registry[e.key], e.value),
      )) {
        bridge.service.invalidate();
      }
      unawaited(bridge._refresh());
    });
    await bridge._refresh();
    return bridge;
  }

  Future<void> _refresh() async {
    final revision = ++_revision;
    final members = <String, PluginRecord>{};
    for (final record in registry.current) {
      if (await authorizer.allows(record.manifest.id)) {
        members[record.manifest.id] = record;
      }
    }
    if (_closed || revision != _revision) return;
    if (members.length != _members.length ||
        members.entries.any((e) => !identical(_members[e.key], e.value))) {
      _members = members;
      service.invalidate(available: members.isNotEmpty);
    }
  }

  Future<void> close() async {
    _closed = true;
    _revision++;
    await _subscription?.cancel();
    await service.close();
  }
}
