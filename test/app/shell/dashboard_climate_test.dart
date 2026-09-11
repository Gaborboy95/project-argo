import 'package:argo/app/shell/dashboard_climate.dart';
import 'package:argo/app/shell/dashboard_temperature.dart';
import 'package:argo/core/climate/climate_service.dart';
import 'package:argo/core/diagnostics/diagnostics_service.dart';
import 'package:argo/integrations/veloce/veloce_vehicle_data_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veloce_lua_core/veloce_lua_core.dart';

void main() {
  testWidgets(
    'unknown, pending, confirmed and failed temperatures never invent feedback',
    (tester) async {
      final data = VehicleDataBus(), diagnostics = DiagnosticsService();
      final service = VehicleClimateService(
        capabilities: ClimateCapabilities.simulation(),
        vehicle: VeloceVehicleDataService(data),
        diagnostics: diagnostics,
        authorize: (_) async => true,
        publish: (_) async {},
      );
      service.invalidate(available: true);
      var opened = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 180,
              width: 200,
              child: ClimateTemperatureControl(
                service: service,
                zone: 'front_left',
                side: 'Left',
                scale: 1,
                onTap: () => opened = true,
              ),
            ),
          ),
        ),
      );
      expect(find.text('--'), findsOneWidget);
      expect(find.text('SIMULATION'), findsNothing);
      await tester.tap(find.byTooltip('Left warmer'));
      await tester.pump();
      expect(find.text('22.5°'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(service.current.temperatures['front_left']!.confirmed, isNull);
      data.publish(
        'climate.front_left.target_temperature_c',
        22.5,
        sourcePluginId: 'selected',
      );
      await tester.pump();
      await tester.pump();
      expect(service.current.temperatures['front_left']!.confirmed, 22.5);
      await tester.tap(find.byTooltip('Left warmer'));
      await tester.pump();
      expect(find.text('23.0°'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      expect(find.text('22.5°'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      service.invalidate();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('temperature-Left')));
      expect(opened, isFalse);
      expect(find.text('--'), findsOneWidget);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DashboardClimate(onDismiss: () {})),
        ),
      );
      expect(find.text('Vehicle climate unavailable'), findsOneWidget);
      expect(find.text('Fan'), findsNothing);
      expect(find.byType(FilterChip), findsNothing);
      expect(tester.takeException(), isNull);
      await service.close();
      await data.close();
    },
  );
}
