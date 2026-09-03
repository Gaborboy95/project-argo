import 'package:veloce_lua_core/veloce_lua_core.dart';

import '../../core/runtime/argo_runtime_mode.dart';
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
    required this.description,
    this.simulationProvider,
    this.socketCanConfiguration,
  });

  final VeloceCanProviderSource source;
  final CanProvider? provider;
  final String description;
  final InMemoryCanProvider? simulationProvider;
  final SocketCanConfiguration? socketCanConfiguration;
}

/// Selects exactly one CAN input policy without coupling Veloce core to it.
Future<VeloceCanProviderSelection> selectVeloceCanProvider({
  required ArgoRuntimeMode runtimeMode,
  required Map<String, String> environment,
  SocketCanProviderStarter? startSocketCan,
}) async {
  if (runtimeMode == ArgoRuntimeMode.simulation) {
    final provider = InMemoryCanProvider(writesEnabled: false);
    return VeloceCanProviderSelection._(
      source: VeloceCanProviderSource.simulation,
      provider: provider,
      simulationProvider: provider,
      description: 'InMemoryCanProvider(simulation, writes=false)',
    );
  }

  final configuration = SocketCanConfiguration.fromEnvironment(environment);
  if (configuration == null) {
    return const VeloceCanProviderSelection._(
      source: VeloceCanProviderSource.failClosed,
      provider: null,
      description: 'disabled (fail-closed)',
    );
  }

  final starter = startSocketCan ?? SocketCanProvider.start;
  final provider = await starter(configuration);
  return VeloceCanProviderSelection._(
    source: VeloceCanProviderSource.socketCan,
    provider: provider,
    socketCanConfiguration: configuration,
    description:
        'SocketCAN(interface=${configuration.interfaceName}, '
        'bus=${configuration.logicalBus}, '
        'writes=${configuration.writesEnabled})',
  );
}
