import 'dart:async';
import 'dart:io';

import 'package:argo/core/diagnostics/diagnostics_service.dart';
import 'package:argo/core/lifecycle/app_lifecycle_coordinator.dart';
import 'package:argo/core/power/head_unit_power_service.dart';
import 'package:argo/core/power/head_unit_power_snapshot.dart';
import 'package:argo/core/power/host_power_controller.dart';
import 'package:argo/core/vehicle/vehicle_power_state.dart';
import 'package:argo/core/vehicle/vehicle_transport_lifecycle.dart';
import 'package:argo/integrations/veloce/host_power_request_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veloce_lua_core/veloce_lua_core.dart';

void main() {
  late _BridgeFixture fixture;

  setUp(() async {
    fixture = await _BridgeFixture.create();
  });

  tearDown(() => fixture.close());

  test('rejects anonymous events', () async {
    fixture.power.setVehicleState(VehiclePowerState.asleep);

    await fixture.publish();

    expect(fixture.controller.calls, 0);
    expect(fixture.latestMessage, contains('anonymous event'));
  });

  test('rejects unrelated plugins', () async {
    fixture.power.setVehicleState(VehiclePowerState.asleep);

    await fixture.publish(sourcePluginId: 'unrelated.plugin');

    expect(fixture.controller.calls, 0);
    expect(fixture.latestMessage, contains('unauthorized plugin'));
  });

  test('rejects a registry record that is not currently loaded', () async {
    fixture.registerRunningPlugin(
      fixture.authorizedPluginId,
      fixture.pluginDirectory,
    );
    fixture.loadedPlugins.clear();
    fixture.power.setVehicleState(VehiclePowerState.asleep);

    await fixture.publish(sourcePluginId: fixture.authorizedPluginId);

    expect(fixture.controller.calls, 0);
    expect(fixture.latestMessage, contains('unauthorized plugin'));
  });

  test('generic profile grants no implicit plugin privilege', () async {
    fixture.registerAuthorizedPlugin();
    await fixture.replaceBridge(withoutActiveIntegration: true);
    fixture.power.setVehicleState(VehiclePowerState.asleep);

    await fixture.publish(sourcePluginId: fixture.authorizedPluginId);

    expect(fixture.controller.calls, 0);
    expect(fixture.latestMessage, contains('unauthorized plugin'));
  });

  test(
    'rejects a running plugin outside the active integration root',
    () async {
      fixture.registerRunningPlugin(
        'outside.plugin',
        fixture.outsidePluginDirectory,
      );
      fixture.power.setVehicleState(VehiclePowerState.asleep);

      await fixture.publish(sourcePluginId: 'outside.plugin');

      expect(fixture.controller.calls, 0);
      expect(fixture.latestMessage, contains('unauthorized plugin'));
    },
  );

  test('accepts a loaded running plugin in the active integration', () async {
    fixture.registerAuthorizedPlugin();
    fixture.power.setVehicleState(VehiclePowerState.asleep);

    await fixture.publish(sourcePluginId: fixture.authorizedPluginId);

    expect(fixture.controller.calls, 1);
    expect(fixture.flushCalls, 1);
    expect(fixture.transport.quiesceCalls, 1);
    expect(fixture.transport.resumeCalls, 1);
  });

  test('rejects a stale request while Argo is awake', () async {
    fixture.registerAuthorizedPlugin();
    fixture.power.setVehicleState(VehiclePowerState.awake);

    await fixture.publish(sourcePluginId: fixture.authorizedPluginId);

    expect(fixture.controller.calls, 0);
    expect(fixture.latestMessage, contains('no longer standby'));
  });

  test('honors only one request per standby episode', () async {
    fixture.registerAuthorizedPlugin();
    fixture.power.setVehicleState(VehiclePowerState.asleep);

    await fixture.publish(sourcePluginId: fixture.authorizedPluginId);
    await fixture.publish(sourcePluginId: fixture.authorizedPluginId);

    expect(fixture.controller.calls, 1);
    expect(fixture.latestMessage, contains('already handled'));
  });

  test('leaving standby resets the episode guard', () async {
    fixture.registerAuthorizedPlugin();
    fixture.power.setVehicleState(VehiclePowerState.asleep);
    await fixture.publish(sourcePluginId: fixture.authorizedPluginId);

    fixture.power.setVehicleState(VehiclePowerState.awake);
    fixture.power.setVehicleState(VehiclePowerState.asleep);
    await fixture.publish(sourcePluginId: fixture.authorizedPluginId);

    expect(fixture.controller.calls, 2);
  });

  test('does not overlap suspend invocations', () async {
    final blockingController = _BlockingHostPowerController();
    await fixture.replaceBridge(controller: blockingController);
    fixture.registerAuthorizedPlugin();
    fixture.power.setVehicleState(VehiclePowerState.asleep);

    fixture.bus.publish(
      HostPowerRequestBridge.suspendRequestTopic,
      null,
      sourcePluginId: fixture.authorizedPluginId,
    );
    fixture.bus.publish(
      HostPowerRequestBridge.suspendRequestTopic,
      null,
      sourcePluginId: fixture.authorizedPluginId,
    );
    await blockingController.started.future;

    expect(blockingController.maximumConcurrentCalls, 1);
    blockingController.release.complete();
    await fixture.bus.flush();
    expect(blockingController.calls, 1);
  });

  test('flushes settings before suspend', () async {
    fixture.registerAuthorizedPlugin();
    fixture.power.setVehicleState(VehiclePowerState.asleep);

    await fixture.publish(sourcePluginId: fixture.authorizedPluginId);

    expect(fixture.order, ['flush', 'quiesce', 'suspend', 'resume']);
  });

  test('settings flush failure does not block suspend', () async {
    await fixture.replaceBridge(flushError: StateError('disk unavailable'));
    fixture.registerAuthorizedPlugin();
    fixture.power.setVehicleState(VehiclePowerState.asleep);

    await fixture.publish(sourcePluginId: fixture.authorizedPluginId);

    expect(fixture.controller.calls, 1);
    expect(
      fixture.diagnostics.snapshot.map((entry) => entry.message),
      contains('Settings flush failed before suspend.'),
    );
  });

  test('suspend failure still attempts transport resume', () async {
    final controller = _RecordingHostPowerController(
      suspendError: StateError('suspend failed'),
    );
    await fixture.replaceBridge(controller: controller);
    fixture.registerAuthorizedPlugin();
    fixture.power.setVehicleState(VehiclePowerState.asleep);

    await fixture.publish(sourcePluginId: fixture.authorizedPluginId);

    expect(controller.suspendCalls, 1);
    expect(fixture.transport.quiesceCalls, 1);
    expect(fixture.transport.resumeCalls, 1);
    expect(
      fixture.diagnostics.snapshot.map((entry) => entry.message),
      contains('Host suspend failed.'),
    );
  });

  test('transport quiesce failure prevents host suspend', () async {
    final transport = _RecordingTransportLifecycle(
      quiesceError: StateError('cannot stop CAN'),
    );
    await fixture.replaceBridge(transport: transport);
    fixture.registerAuthorizedPlugin();
    fixture.power.setVehicleState(VehiclePowerState.asleep);

    await fixture.publish(sourcePluginId: fixture.authorizedPluginId);

    expect(fixture.controller.suspendCalls, 0);
    expect(transport.quiesceCalls, 1);
    expect(transport.resumeCalls, 0);
    expect(fixture.latestMessage, 'CAN transport quiesce failed.');
  });

  test('transport resume failure is diagnosed', () async {
    final transport = _RecordingTransportLifecycle(
      resumeError: StateError('cannot reopen CAN'),
    );
    await fixture.replaceBridge(transport: transport);
    fixture.registerAuthorizedPlugin();
    fixture.power.setVehicleState(VehiclePowerState.asleep);

    await fixture.publish(sourcePluginId: fixture.authorizedPluginId);

    expect(fixture.controller.suspendCalls, 1);
    expect(transport.resumeCalls, 1);
    expect(fixture.latestMessage, 'CAN transport resume failed.');
  });

  test('disabled backend validates once and never suspends', () async {
    const disabled = _DisabledRecordingController();
    await fixture.replaceBridge(controller: disabled);
    fixture.registerAuthorizedPlugin();
    fixture.power.setVehicleState(VehiclePowerState.asleep);

    await fixture.publish(sourcePluginId: fixture.authorizedPluginId);
    await fixture.publish(sourcePluginId: fixture.authorizedPluginId);

    expect(disabled.calls, 0);
    expect(fixture.flushCalls, 0);
    expect(fixture.transport.quiesceCalls, 0);
    expect(fixture.transport.resumeCalls, 0);
    expect(
      fixture.diagnostics.snapshot
          .where(
            (entry) =>
                entry.message ==
                'Host power control disabled; suspend suppressed.',
          )
          .length,
      1,
    );
  });

  test('rejects anonymous and unauthorized shutdown requests', () async {
    await fixture.publish(topic: HostPowerRequestBridge.shutdownRequestTopic);
    expect(fixture.latestMessage, contains('anonymous event'));

    await fixture.publish(
      topic: HostPowerRequestBridge.shutdownRequestTopic,
      sourcePluginId: 'unrelated.plugin',
    );

    expect(fixture.controller.powerOffCalls, 0);
    expect(fixture.latestMessage, contains('unauthorized plugin'));
  });

  test('authorized shutdown flushes and quiesces before poweroff', () async {
    fixture.registerAuthorizedPlugin();
    fixture.power.setVehicleState(VehiclePowerState.awake);

    await fixture.publish(
      topic: HostPowerRequestBridge.shutdownRequestTopic,
      sourcePluginId: fixture.authorizedPluginId,
    );

    expect(fixture.controller.powerOffCalls, 1);
    expect(fixture.transport.quiesceCalls, 1);
    expect(fixture.transport.resumeCalls, 0);
    expect(fixture.order, ['flush', 'quiesce', 'poweroff']);
  });

  test('settings flush failure does not block shutdown', () async {
    await fixture.replaceBridge(flushError: StateError('disk unavailable'));
    fixture.registerAuthorizedPlugin();

    await fixture.publish(
      topic: HostPowerRequestBridge.shutdownRequestTopic,
      sourcePluginId: fixture.authorizedPluginId,
    );

    expect(fixture.controller.powerOffCalls, 1);
    expect(
      fixture.diagnostics.snapshot.map((entry) => entry.message),
      contains('Settings flush failed before shutdown.'),
    );
  });

  test('disabled shutdown performs no transport or host operation', () async {
    const controller = _DisabledRecordingController();
    await fixture.replaceBridge(controller: controller);
    fixture.registerAuthorizedPlugin();

    await fixture.publish(
      topic: HostPowerRequestBridge.shutdownRequestTopic,
      sourcePluginId: fixture.authorizedPluginId,
    );

    expect(controller.calls, 0);
    expect(fixture.transport.quiesceCalls, 0);
    expect(fixture.transport.resumeCalls, 0);
    expect(fixture.flushCalls, 0);
    expect(
      fixture.latestMessage,
      'Host power control disabled; shutdown suppressed.',
    );
  });

  test('poweroff failure attempts transport recovery', () async {
    final controller = _RecordingHostPowerController(
      powerOffError: StateError('poweroff failed'),
    );
    await fixture.replaceBridge(controller: controller);
    fixture.registerAuthorizedPlugin();

    await fixture.publish(
      topic: HostPowerRequestBridge.shutdownRequestTopic,
      sourcePluginId: fixture.authorizedPluginId,
    );

    expect(controller.powerOffCalls, 1);
    expect(fixture.transport.quiesceCalls, 1);
    expect(fixture.transport.resumeCalls, 1);
    expect(
      fixture.diagnostics.snapshot.map((entry) => entry.message),
      contains('Host shutdown failed.'),
    );
  });

  test('concurrent host power operations are suppressed', () async {
    final controller = _BlockingHostPowerController();
    await fixture.replaceBridge(controller: controller);
    fixture.registerAuthorizedPlugin();
    fixture.power.setVehicleState(VehiclePowerState.asleep);

    fixture.bus.publish(
      HostPowerRequestBridge.suspendRequestTopic,
      null,
      sourcePluginId: fixture.authorizedPluginId,
    );
    await controller.started.future;
    fixture.bus.publish(
      HostPowerRequestBridge.shutdownRequestTopic,
      null,
      sourcePluginId: fixture.authorizedPluginId,
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.powerOffCalls, 0);
    expect(
      fixture.diagnostics.snapshot.map((entry) => entry.message),
      contains(
        'Host shutdown request suppressed: another host power operation is '
        'in progress.',
      ),
    );
    controller.release.complete();
    await fixture.bus.flush();
  });

  test(
    'bridge cleanup removes subscriptions and rejects future events',
    () async {
      fixture.registerAuthorizedPlugin();
      fixture.power.setVehicleState(VehiclePowerState.asleep);
      expect(
        fixture.bus.subscriptionCountFor('argo.host-power-request-bridge'),
        2,
      );
      expect(fixture.power.listenerCount, 1);

      await fixture.bridge.close();
      fixture.bus.publish(
        HostPowerRequestBridge.suspendRequestTopic,
        null,
        sourcePluginId: fixture.authorizedPluginId,
      );
      await fixture.bus.flush();

      expect(
        fixture.bus.subscriptionCountFor('argo.host-power-request-bridge'),
        0,
      );
      expect(fixture.power.listenerCount, 0);
      expect(fixture.controller.calls, 0);
    },
  );

  test(
    'lifecycle stops the bridge before downstream power resources',
    () async {
      final calls = <String>[];
      final lifecycle = AppLifecycleCoordinator()
        ..registerShutdown(
          name: 'power',
          shutdown: () {
            expect(
              fixture.bus.subscriptionCountFor(
                'argo.host-power-request-bridge',
              ),
              0,
            );
            calls.add('power');
          },
        )
        ..registerShutdown(
          name: 'bridge',
          phase: AppShutdownPhase.stopActivity,
          shutdown: () async {
            await fixture.bridge.close();
            calls.add('bridge');
          },
        );

      await lifecycle.shutdown();

      expect(calls, ['bridge', 'power']);
    },
  );
}

final class _BridgeFixture {
  _BridgeFixture._({
    required this.root,
    required this.pluginDirectory,
    required this.outsidePluginDirectory,
    required this.bus,
    required this.registry,
    required this.power,
    required this.diagnostics,
    required this.controller,
    required this.transport,
    required this.bridge,
  });

  String get authorizedPluginId => 'example.power-policy';

  final Directory root;
  final Directory pluginDirectory;
  final Directory outsidePluginDirectory;
  final PluginEventBus bus;
  final PluginRegistry registry;
  final _FakeHeadUnitPowerService power;
  final DiagnosticsService diagnostics;
  _RecordingHostPowerController controller;
  _RecordingTransportLifecycle transport;
  HostPowerRequestBridge bridge;
  final Set<String> loadedPlugins = {};
  final List<String> order = [];
  var flushCalls = 0;

  String? get latestMessage => diagnostics.latest?.message;

  static Future<_BridgeFixture> create() async {
    final root = await Directory.systemTemp.createTemp('argo-host-power-');
    final pluginDirectory = Directory.fromUri(
      root.uri.resolve('plugins/power/'),
    );
    final outsidePluginDirectory = Directory.fromUri(
      root.uri.resolve('outside/'),
    );
    await pluginDirectory.create(recursive: true);
    await outsidePluginDirectory.create(recursive: true);
    final bus = PluginEventBus();
    final registry = PluginRegistry();
    final power = _FakeHeadUnitPowerService();
    final diagnostics = DiagnosticsService();
    final controller = _RecordingHostPowerController();
    final transport = _RecordingTransportLifecycle();
    late final _BridgeFixture fixture;
    final bridge = await HostPowerRequestBridge.start(
      eventBus: bus,
      pluginRegistry: registry,
      isPluginLoaded: (pluginId) => fixture.loadedPlugins.contains(pluginId),
      activeIntegrationPluginRoot: Directory.fromUri(
        root.uri.resolve('plugins/'),
      ),
      powerService: power,
      hostPowerController: controller,
      transportLifecycle: transport,
      flushSettings: () async {
        fixture.flushCalls++;
        fixture.order.add('flush');
      },
      diagnostics: diagnostics,
    );
    fixture = _BridgeFixture._(
      root: root,
      pluginDirectory: pluginDirectory,
      outsidePluginDirectory: outsidePluginDirectory,
      bus: bus,
      registry: registry,
      power: power,
      diagnostics: diagnostics,
      controller: controller,
      transport: transport,
      bridge: bridge,
    );
    controller.order = fixture.order;
    transport.order = fixture.order;
    return fixture;
  }

  void registerAuthorizedPlugin() {
    registerRunningPlugin(authorizedPluginId, pluginDirectory);
  }

  void registerRunningPlugin(String pluginId, Directory directory) {
    registry.put(
      PluginRecord(
        directoryPath: directory.path,
        manifest: PluginManifest(
          id: pluginId,
          name: pluginId,
          version: const SemanticVersion(major: 1, minor: 0, patch: 0),
          apiVersion: '1',
          entrypoint: 'main.lua',
          permissions: const [],
        ),
        state: PluginState.running,
        enabled: true,
      ),
    );
    loadedPlugins.add(pluginId);
  }

  Future<void> publish({
    String? sourcePluginId,
    String topic = HostPowerRequestBridge.suspendRequestTopic,
  }) async {
    bus.publish(topic, null, sourcePluginId: sourcePluginId);
    await bus.flush();
  }

  Future<void> replaceBridge({
    HostPowerController? controller,
    VehicleTransportLifecycle? transport,
    Object? flushError,
    bool withoutActiveIntegration = false,
  }) async {
    await bridge.close();
    final replacement = controller ?? this.controller;
    final replacementTransport = transport ?? this.transport;
    if (replacement is _RecordingHostPowerController) {
      this.controller = replacement;
      replacement.order = order;
    }
    if (replacementTransport is _RecordingTransportLifecycle) {
      this.transport = replacementTransport;
      replacementTransport.order = order;
    }
    bridge = await HostPowerRequestBridge.start(
      eventBus: bus,
      pluginRegistry: registry,
      isPluginLoaded: loadedPlugins.contains,
      activeIntegrationPluginRoot: withoutActiveIntegration
          ? null
          : Directory.fromUri(root.uri.resolve('plugins/')),
      powerService: power,
      hostPowerController: replacement,
      transportLifecycle: replacementTransport,
      flushSettings: () async {
        flushCalls++;
        order.add('flush');
        if (flushError != null) throw flushError;
      },
      diagnostics: diagnostics,
    );
  }

  Future<void> close() async {
    await bridge.close();
    await power.close();
    await bus.close();
    await registry.close();
    await root.delete(recursive: true);
  }
}

final class _FakeHeadUnitPowerService implements HeadUnitPowerService {
  final StreamController<HeadUnitPowerSnapshot> _changes =
      StreamController.broadcast(sync: true);
  HeadUnitPowerSnapshot _current = const HeadUnitPowerSnapshot();
  var listenerCount = 0;

  _FakeHeadUnitPowerService() {
    _changes.onListen = () => listenerCount++;
    _changes.onCancel = () => listenerCount--;
  }

  @override
  HeadUnitPowerSnapshot get current => _current;

  @override
  Stream<HeadUnitPowerSnapshot> get changes => _changes.stream;

  void setVehicleState(VehiclePowerState state) {
    _current = HeadUnitPowerSnapshot(vehiclePowerState: state);
    _changes.add(_current);
  }

  @override
  Future<void> close() => _changes.close();
}

class _RecordingHostPowerController implements HostPowerController {
  _RecordingHostPowerController({this.suspendError, this.powerOffError});

  final Object? suspendError;
  final Object? powerOffError;
  List<String>? order;
  var suspendCalls = 0;
  var powerOffCalls = 0;

  int get calls => suspendCalls;

  @override
  bool get isEnabled => true;

  @override
  Future<void> suspend() async {
    suspendCalls++;
    order?.add('suspend');
    if (suspendError != null) throw suspendError!;
  }

  @override
  Future<void> powerOff() async {
    powerOffCalls++;
    order?.add('poweroff');
    if (powerOffError != null) throw powerOffError!;
  }
}

final class _BlockingHostPowerController extends _RecordingHostPowerController {
  final started = Completer<void>();
  final release = Completer<void>();
  var concurrentCalls = 0;
  var maximumConcurrentCalls = 0;

  @override
  Future<void> suspend() async {
    suspendCalls++;
    concurrentCalls++;
    if (concurrentCalls > maximumConcurrentCalls) {
      maximumConcurrentCalls = concurrentCalls;
    }
    if (!started.isCompleted) started.complete();
    await release.future;
    concurrentCalls--;
  }
}

final class _DisabledRecordingController implements HostPowerController {
  const _DisabledRecordingController();

  int get calls => 0;

  @override
  bool get isEnabled => false;

  @override
  Future<void> suspend() => throw StateError('Disabled controller was called.');

  @override
  Future<void> powerOff() =>
      throw StateError('Disabled controller was called.');
}

final class _RecordingTransportLifecycle implements VehicleTransportLifecycle {
  _RecordingTransportLifecycle({this.quiesceError, this.resumeError});

  final Object? quiesceError;
  final Object? resumeError;
  List<String>? order;
  var quiesceCalls = 0;
  var resumeCalls = 0;

  @override
  Future<void> quiesce() async {
    quiesceCalls++;
    order?.add('quiesce');
    if (quiesceError != null) throw quiesceError!;
  }

  @override
  Future<void> resume() async {
    resumeCalls++;
    order?.add('resume');
    if (resumeError != null) throw resumeError!;
  }
}
