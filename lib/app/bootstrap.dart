import 'package:flutter/widgets.dart';

import '../core/services/service_registry.dart';
import '../integrations/veloce/socket_can_provider.dart';
import '../integrations/veloce/veloce_runtime.dart';
import '../integrations/veloce/veloce_runtime_lifecycle.dart';
import 'app.dart';
import 'argo_environment.dart';
import 'navigation/app_module_registry.dart';
import 'navigation/app_modules.dart';

/// Composes Project Argo and starts its application-owned integrations.
Future<Widget> bootstrapArgoApplication({
  required Map<String, String> processEnvironment,
}) async {
  final veloceConfiguration = VeloceRuntimeConfiguration.fromEnvironment(
    environment: processEnvironment,
  );
  final socketCanConfiguration = SocketCanConfiguration.fromEnvironment(
    processEnvironment,
  );
  final canProvider = socketCanConfiguration == null
      ? null
      : await SocketCanProvider.start(socketCanConfiguration);
  final veloceRuntime = await VeloceRuntime.start(
    configuration: veloceConfiguration,
    canProvider: canProvider,
    canProviderDescription: socketCanConfiguration == null
        ? null
        : 'SocketCAN(interface=${socketCanConfiguration.interfaceName}, '
              'bus=${socketCanConfiguration.logicalBus}, '
              'writes=${socketCanConfiguration.writesEnabled})',
  );

  try {
    final services = ServiceRegistry()..register(veloceRuntime);
    final moduleRegistry = AppModuleRegistry();
    registerBuiltInAppModules(moduleRegistry);
    final environment = ArgoEnvironment(
      services: services,
      moduleRegistry: moduleRegistry,
    );

    return VeloceRuntimeLifecycle(
      runtime: services.get<VeloceRuntime>(),
      child: ArgoApp(environment: environment),
    );
  } on Object {
    await veloceRuntime.shutdown();
    rethrow;
  }
}
