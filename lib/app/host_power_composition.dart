import '../core/diagnostics/diagnostics_service.dart';
import '../core/lifecycle/app_lifecycle_coordinator.dart';
import '../core/power/head_unit_power_service.dart';
import '../core/power/host_power_controller.dart';
import '../core/settings/settings_service.dart';
import '../core/services/service_registry.dart';
import '../core/vehicle/integration/vehicle_integration_bundle.dart';
import '../integrations/host_power/host_power_controller_selection.dart';
import '../integrations/host_power/linux_systemd_host_power_controller.dart';
import '../integrations/veloce/host_power_request_bridge.dart';
import '../integrations/veloce/veloce_runtime.dart';

/// Selects the host backend and binds its only privileged request to Veloce.
Future<HostPowerRequestBridge> registerHostPowerServices({
  required ServiceRegistry services,
  required AppLifecycleCoordinator lifecycle,
  required DiagnosticsService diagnostics,
  required Map<String, String> environment,
  required VehicleIntegrationBundle? activeVehicleIntegration,
  bool? isLinux,
  HostProcessRunner? processRunner,
}) async {
  final controller = selectHostPowerController(
    environment: environment,
    isLinux: isLinux,
    processRunner: processRunner,
  );
  services.register<HostPowerController>(controller);

  final veloce = services.get<VeloceRuntime>();
  final bridge = await HostPowerRequestBridge.start(
    eventBus: veloce.pluginManager.eventBus,
    pluginRegistry: veloce.pluginManager.pluginRegistry,
    isPluginLoaded: veloce.pluginManager.isLoaded,
    activeIntegrationPluginRoot:
        activeVehicleIntegration?.velocePluginDirectory,
    powerService: services.get<HeadUnitPowerService>(),
    hostPowerController: controller,
    flushSettings: services.get<SettingsService>().flush,
    diagnostics: diagnostics,
  );
  lifecycle.registerShutdown(
    name: 'hostPower.requestBridge',
    phase: AppShutdownPhase.stopActivity,
    shutdown: bridge.close,
  );
  services.register(bridge);
  return bridge;
}
