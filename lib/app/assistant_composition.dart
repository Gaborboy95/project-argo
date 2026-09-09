import '../core/audio/audio_service.dart';
import '../core/diagnostics/diagnostics_service.dart';
import '../core/lifecycle/app_lifecycle_coordinator.dart';
import '../core/services/service_registry.dart';
import '../integrations/assistant/assistant_bridge.dart';
import '../integrations/assistant/assistant_bridge_configuration.dart';
import '../integrations/veloce/veloce_runtime.dart';

/// Explicit opt-in: missing credentials or invalid grants abort startup.
Future<AssistantBridge?> registerAssistantServices({
  required ServiceRegistry services,
  required AppLifecycleCoordinator lifecycle,
  required DiagnosticsService diagnostics,
  required Map<String, String> environment,
}) async {
  final configuration = await AssistantBridgeConfiguration.fromEnvironment(
    environment,
  );
  if (configuration == null) return null;
  final veloce = services.get<VeloceRuntime>();
  final bridge = await AssistantBridge.start(
    configuration: configuration,
    eventBus: veloce.pluginManager.eventBus,
    vehicleDataBus: veloce.vehicleDataBus,
    audio: services.get<AudioService>(),
    isPluginLoaded: veloce.pluginManager.isLoaded,
  );
  lifecycle.registerShutdown(
    name: 'assistant.bridge',
    phase: AppShutdownPhase.stopActivity,
    shutdown: bridge.close,
  );
  services.register(bridge);
  diagnostics.info(
    'assistant.bridge',
    'Local assistant bridge ready on 127.0.0.1:${bridge.port}.',
  );
  return bridge;
}
