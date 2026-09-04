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

    await tester.pumpWidget(
      MaterialApp(home: VehiclePage(vehicleData: vehicleData)),
    );

    expect(find.text('Engine speed'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);
    expect(find.textContaining('RPM'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await bus.close();
  });

  testWidgets('updates live to 3000 RPM', (tester) async {
    final bus = veloce.VehicleDataBus();
    final vehicleData = VeloceVehicleDataService(bus);
    await tester.pumpWidget(
      MaterialApp(home: VehiclePage(vehicleData: vehicleData)),
    );

    bus.publish('engine.rpm', 3000, sourcePluginId: 'dev.example.can_decoder');
    await bus.flush();
    await tester.pump();

    expect(find.text('3000 RPM'), findsOneWidget);
    expect(find.text('—'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await bus.close();
  });
}
