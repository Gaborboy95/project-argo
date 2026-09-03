import 'package:argo/core/runtime/argo_runtime_mode.dart';
import 'package:argo/integrations/veloce/socket_can_provider.dart';
import 'package:argo/integrations/veloce/veloce_can_provider_selection.dart';
import 'package:veloce_lua_core/veloce_lua_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('production without explicit SocketCAN remains fail-closed', () async {
    var socketCanStarted = false;

    final selection = await selectVeloceCanProvider(
      runtimeMode: ArgoRuntimeMode.production,
      environment: const {},
      startSocketCan: (configuration) async {
        socketCanStarted = true;
        return InMemoryCanProvider();
      },
    );

    expect(selection.source, VeloceCanProviderSource.failClosed);
    expect(selection.provider, isNull);
    expect(socketCanStarted, isFalse);
  });

  test(
    'production explicitly selects the configured SocketCAN provider',
    () async {
      final provider = InMemoryCanProvider();
      SocketCanConfiguration? startedConfiguration;

      final selection = await selectVeloceCanProvider(
        runtimeMode: ArgoRuntimeMode.production,
        environment: const {
          'VELOCE_CAN_INPUT': 'socketcan',
          'VELOCE_SOCKETCAN_INTERFACE': 'vcan0',
          'VELOCE_CAN_BUS': 'comfort',
        },
        startSocketCan: (configuration) async {
          startedConfiguration = configuration;
          return provider;
        },
      );

      expect(selection.source, VeloceCanProviderSource.socketCan);
      expect(selection.provider, same(provider));
      expect(startedConfiguration?.interfaceName, 'vcan0');
      expect(startedConfiguration?.logicalBus, 'comfort');
      await provider.close();
    },
  );

  test('simulation selects a write-disabled in-memory provider', () async {
    final selection = await selectVeloceCanProvider(
      runtimeMode: ArgoRuntimeMode.simulation,
      environment: const {},
    );

    expect(selection.source, VeloceCanProviderSource.simulation);
    expect(selection.provider, same(selection.simulationProvider));
    expect(selection.simulationProvider, isA<InMemoryCanProvider>());
    expect(selection.simulationProvider!.writesEnabled, isFalse);
    await selection.simulationProvider!.close();
  });

  test('simulation never constructs SocketCAN even when configured', () async {
    var socketCanStarted = false;

    final selection = await selectVeloceCanProvider(
      runtimeMode: ArgoRuntimeMode.simulation,
      environment: const {
        'VELOCE_CAN_INPUT': 'socketcan',
        'VELOCE_SOCKETCAN_INTERFACE': 'can0',
        'VELOCE_CAN_WRITE_ENABLED': 'not-a-boolean',
      },
      startSocketCan: (configuration) async {
        socketCanStarted = true;
        throw StateError('SocketCAN must not start in simulation.');
      },
    );

    expect(socketCanStarted, isFalse);
    expect(selection.source, VeloceCanProviderSource.simulation);
    await selection.simulationProvider!.close();
  });
}
