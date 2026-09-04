import '../core/audio/audio_backend.dart';
import '../core/audio/audio_service.dart';
import '../core/diagnostics/diagnostics_service.dart';
import '../core/lifecycle/app_lifecycle_coordinator.dart';
import '../core/services/service_registry.dart';
import '../core/settings/settings_service.dart';
import '../core/vehicle/integration/vehicle_integration_bundle.dart';
import '../integrations/audio/audio_backend_selection.dart';
import '../integrations/audio/pipewire_audio_backend.dart';
import '../integrations/veloce/vehicle_audio_control_bridge.dart';
import '../integrations/veloce/veloce_runtime.dart';

Future<VehicleAudioControlBridge> registerAudioServices({
  required ServiceRegistry services,
  required AppLifecycleCoordinator lifecycle,
  required DiagnosticsService diagnostics,
  required Map<String, String> environment,
  required VehicleIntegrationBundle? activeVehicleIntegration,
  bool? isLinux,
  AudioProcessRunner? processRunner,
}) async {
  final backend = selectAudioBackend(
    environment: environment,
    isLinux: isLinux,
    processRunner: processRunner,
  );
  final audio = await registerAudioCoreServices(
    services: services,
    lifecycle: lifecycle,
    diagnostics: diagnostics,
    backend: backend,
  );
  diagnostics.info(
    'audio.backend',
    audio.current.backendAvailable
        ? 'Audio backend ready.'
        : 'Audio backend disabled.',
  );

  final veloce = services.get<VeloceRuntime>();
  final bridge = await VehicleAudioControlBridge.start(
    eventBus: veloce.pluginManager.eventBus,
    pluginRegistry: veloce.pluginManager.pluginRegistry,
    isPluginLoaded: veloce.pluginManager.isLoaded,
    activeIntegrationPluginRoot:
        activeVehicleIntegration?.velocePluginDirectory,
    audio: audio,
    diagnostics: diagnostics,
  );
  lifecycle.registerShutdown(
    name: 'audio.vehicleControlBridge',
    phase: AppShutdownPhase.stopActivity,
    shutdown: bridge.close,
  );
  services.register(bridge);
  return bridge;
}

Future<AudioService> registerAudioCoreServices({
  required ServiceRegistry services,
  required AppLifecycleCoordinator lifecycle,
  required DiagnosticsService diagnostics,
  required AudioBackend backend,
}) async {
  final audio = await DefaultAudioService.start(
    backend: backend,
    settings: services.get<SettingsService>(),
    diagnostics: diagnostics,
  );
  lifecycle.registerShutdown(name: 'audio.service', shutdown: audio.close);
  services
    ..register<AudioBackend>(backend)
    ..register<AudioService>(audio);
  return audio;
}
