import 'package:veloce_lua_core/veloce_lua_core.dart';

import '../../core/runtime/argo_runtime_mode.dart';
import '../../core/vehicle/vehicle_transport_lifecycle.dart';
import 'restartable_can_provider.dart';
import 'socket_can_provider.dart';

typedef SocketCanProviderStarter = Future<CanProvider> Function(
  SocketCanConfiguration configuration,
);

enum VeloceCanProviderSource { failClosed, socketCan, simulation }

/// The transport decision made once during application composition.
final class VeloceCanProviderSelection {
  const VeloceCanProviderSelection._({
    required this.source,
    required this.provider,
    required this.transportLifecycle,
    required this.description,
    this.simulationProvider,
    this.socketCanConfiguration,
  });

  final VeloceCanProviderSource source;
  final CanProvider? provider;
  final VehicleTransportLifecycle transportLifecycle;
  final String description;
  final InMemoryCanProvider? simulationProvider;
  final SocketCanConfiguration? socketCanConfiguration;
}

/// Selects exactly one CAN input policy without coupling Veloce core to it.
Future<VeloceCanProviderSelection> selectVeloceCanProvider({
  required ArgoRuntimeMode runtimeMode,
  required Map<String, String> environment,
  SocketCanProviderStarter? startSocketCan,
  SocketCanErrorHandler? onSocketCanError,
  CanProviderErrorHandler? onCanHandlerError,
}) async {
  if (runtimeMode == ArgoRuntimeMode.simulation) {
    final provider = InMemoryCanProvider(
      writesEnabled: false,
      onHandlerError: onCanHandlerError,
    );
    return VeloceCanProviderSelection._(
      source: VeloceCanProviderSource.simulation,
      provider: provider,
      transportLifecycle: const NoOpVehicleTransportLifecycle(),
      simulationProvider: provider,
      description: 'InMemoryCanProvider(simulation, writes=false)',
    );
  }

  final configuration = SocketCanConfiguration.fromEnvironment(environment);
  if (configuration == null) {
    return const VeloceCanProviderSelection._(
      source: VeloceCanProviderSource.failClosed,
      provider: null,
      transportLifecycle: NoOpVehicleTransportLifecycle(),
      description: 'disabled (fail-closed)',
    );
  }

  Future<CanProvider> createDelegate() => startSocketCan == null
      ? SocketCanProvider.start(configuration, onError: onSocketCanError)
      : startSocketCan(configuration);

  final provider = await RestartableCanProvider.start(
    delegateFactory: createDelegate,
    writesEnabled: configuration.writesEnabled,
  );
  return VeloceCanProviderSelection._(
    source: VeloceCanProviderSource.socketCan,
    provider: provider,
    transportLifecycle: provider,
    socketCanConfiguration: configuration,
    description:
        'RestartableSocketCAN(interface=${configuration.interfaceName}, '
        'bus=${configuration.logicalBus}, '
        'writes=${configuration.writesEnabled})',
  );
}
