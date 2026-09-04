import 'package:argo/core/power/vehicle_data_head_unit_power_service.dart';
import 'package:argo/features/vehicle/vehicle_page.dart';
import 'package:argo/integrations/veloce/veloce_vehicle_data_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veloce_lua_core/veloce_lua_core.dart' as veloce;

void main() {
  testWidgets('shows a waiting state while engine RPM is unavailable', (
    tester,
  ) async {
    final bus = veloce.VehicleDataBus();
    final vehicleData = VeloceVehicleDataService(bus);
    final power = VehicleDataHeadUnitPowerService(vehicleData: vehicleData);

    await tester.pumpWidget(
      MaterialApp(
        home: VehiclePage(vehicleData: vehicleData, power: power),
      ),
    );

    expect(find.text('Engine speed'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('vehicle.engineRpm'))).data,
      '—',
    );
    expect(find.textContaining('RPM'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await power.close();
    await bus.close();
  });

  testWidgets('updates live to 3000 RPM', (tester) async {
    final bus = veloce.VehicleDataBus();
    final vehicleData = VeloceVehicleDataService(bus);
    final power = VehicleDataHeadUnitPowerService(vehicleData: vehicleData);
    await tester.pumpWidget(
      MaterialApp(
        home: VehiclePage(vehicleData: vehicleData, power: power),
      ),
    );

    bus.publish('engine.rpm', 3000, sourcePluginId: 'dev.example.can_decoder');
    await bus.flush();
    await tester.pump();

    expect(find.text('3000 RPM'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('vehicle.engineRpm'))).data,
      '3000 RPM',
    );

    await tester.pumpWidget(const SizedBox());
    await power.close();
    await bus.close();
  });

  testWidgets(
    'shows normalized power information without transport knowledge',
    (tester) async {
      final bus = veloce.VehicleDataBus();
      final vehicleData = VeloceVehicleDataService(bus);
      final power = VehicleDataHeadUnitPowerService(vehicleData: vehicleData);
      await tester.pumpWidget(
        MaterialApp(
          home: VehiclePage(vehicleData: vehicleData, power: power),
        ),
      );

      bus.publish('vehicle.power.state', 'asleep');
      bus.publish('vehicle.ignition.state', 'accessory');
      bus.publish('vehicle.battery.voltage', 12.4);
      await bus.flush();
      await tester.pump();

      expect(find.text('Vehicle power: '), findsOneWidget);
      expect(find.text('asleep'), findsOneWidget);
      expect(find.text('Ignition: '), findsOneWidget);
      expect(find.text('accessory'), findsOneWidget);
      expect(find.text('12.4 V'), findsOneWidget);
      expect(find.text('standby'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await power.close();
      await bus.close();
    },
  );
}
