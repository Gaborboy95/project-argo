import '../core/climate/climate_service.dart';
import '../core/diagnostics/diagnostics_service.dart';
import '../core/lifecycle/app_lifecycle_coordinator.dart';
import '../core/services/service_registry.dart';
import '../core/vehicle/integration/vehicle_integration_bundle.dart';
import '../core/vehicle/vehicle_capability.dart';
import '../core/vehicle/vehicle_data_service.dart';
import '../core/vehicle/vehicle_profile.dart';
import '../integrations/veloce/vehicle_climate_bridge.dart';
import '../integrations/veloce/veloce_runtime.dart';

Future<void> registerClimateService({
  required ServiceRegistry services,
  required AppLifecycleCoordinator lifecycle,
  required DiagnosticsService diagnostics,
  required VehicleIntegrationBundle? integration,
  required bool simulated,
}) async {
  if (simulated) {
    final service = VehicleClimateService(
      capabilities: ClimateCapabilities.simulation(),
      simulated: true,
      publish: (_) async {},
      authorize: (id) async => id == 'argo.simulation',
      diagnostics: diagnostics,
    );
    service.invalidate(available: true);
    services.register<ClimateService>(service);
    lifecycle.registerShutdown(
      name: 'climate.simulation',
      phase: AppShutdownPhase.stopActivity,
      shutdown: service.close,
    );
    return;
  }
  final profile = services.get<VehicleProfile>();
  final runtime = services.get<VeloceRuntime>();
  final bridge = await VehicleClimateBridge.start(
    registry: runtime.pluginManager.pluginRegistry,
    events: runtime.pluginManager.eventBus,
    isLoaded: runtime.pluginManager.isLoaded,
    root: integration?.velocePluginDirectory,
    capabilities:
        profile.capabilities.contains(VehicleCapabilities.climateControl)
        ? profile.climate
        : null,
    vehicle: services.get<VehicleDataService>(),
    diagnostics: diagnostics,
  );
  services.register<ClimateService>(bridge.service);
  lifecycle.registerShutdown(
    name: 'climate.vehicle',
    phase: AppShutdownPhase.stopActivity,
    shutdown: bridge.close,
  );
}
