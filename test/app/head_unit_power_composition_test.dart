import 'package:argo/app/head_unit_power_composition.dart';
import 'package:argo/core/diagnostics/diagnostics_service.dart';
import 'package:argo/core/lifecycle/app_lifecycle_coordinator.dart';
import 'package:argo/core/power/head_unit_power_service.dart';
import 'package:argo/core/services/service_registry.dart';
import 'package:argo/core/vehicle/vehicle_data_service.dart';
import 'package:argo/integrations/veloce/veloce_vehicle_data_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veloce_lua_core/veloce_lua_core.dart' as veloce;

void main() {
  test('registers power service and cleans it before vehicle data', () async {
    final bus = veloce.VehicleDataBus();
    final vehicleData = VeloceVehicleDataService(bus);
    final services = ServiceRegistry()
      ..register<VehicleDataService>(vehicleData);
    final diagnostics = DiagnosticsService();
    final lifecycle = AppLifecycleCoordinator();
    var vehicleDataDestroyed = false;
    lifecycle.registerShutdown(
      name: 'test.vehicleData',
      shutdown: () {
        expect(_powerSubscriptionCount(bus), 0);
        vehicleDataDestroyed = true;
      },
    );

    final power = registerHeadUnitPowerService(
      services: services,
      lifecycle: lifecycle,
      diagnostics: diagnostics,
    );

    expect(services.get<HeadUnitPowerService>(), same(power));
    expect(_powerSubscriptionCount(bus), 3);
    bus.publish('vehicle.power.state', 'awake');
    await bus.flush();
    expect(diagnostics.latest?.source, 'vehicle.power');
    expect(diagnostics.latest?.message, 'Vehicle power: unknown → awake.');

    await lifecycle.shutdown();

    expect(vehicleDataDestroyed, isTrue);
    expect(_powerSubscriptionCount(bus), 0);
    await bus.close();
  });
}

int _powerSubscriptionCount(veloce.VehicleDataBus bus) =>
    bus.subscriptionCountFor('argo.vehicle-data.1') +
    bus.subscriptionCountFor('argo.vehicle-data.2') +
    bus.subscriptionCountFor('argo.vehicle-data.3');
