import '../core/diagnostics/diagnostics_service.dart';
import '../core/lifecycle/app_lifecycle_coordinator.dart';
import '../core/power/head_unit_power_service.dart';
import '../core/power/vehicle_data_head_unit_power_service.dart';
import '../core/services/service_registry.dart';
import '../core/vehicle/vehicle_data_service.dart';

/// Constructs, registers, and lifecycle-owns Argo's normalized power service.
HeadUnitPowerService registerHeadUnitPowerService({
  required ServiceRegistry services,
  required AppLifecycleCoordinator lifecycle,
  required DiagnosticsService diagnostics,
}) {
  final power = VehicleDataHeadUnitPowerService(
    vehicleData: services.get<VehicleDataService>(),
    onVehiclePowerStateChanged: (previous, current) {
      diagnostics.info(
        'vehicle.power',
        'Vehicle power: ${previous.wireValue} → ${current.wireValue}.',
      );
    },
    onError: (error, stackTrace) {
      diagnostics.warning(
        'vehicle.power',
        'Could not process normalized vehicle power data.',
        error: error,
        stackTrace: stackTrace,
      );
    },
  );
  lifecycle.registerShutdown(name: 'headUnit.power', shutdown: power.close);
  services.register<HeadUnitPowerService>(power);
  return power;
}
