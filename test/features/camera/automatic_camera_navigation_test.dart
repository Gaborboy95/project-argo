import 'dart:async';

import 'package:argo/app/argo_environment.dart';
import 'package:argo/app/navigation/app_module.dart';
import 'package:argo/app/navigation/app_module_registry.dart';
import 'package:argo/app/shell/app_shell.dart';
import 'package:argo/core/camera/camera_presentation_policy.dart';
import 'package:argo/core/camera/camera_service.dart';
import 'package:argo/core/services/service_registry.dart';
import 'package:argo/core/settings/app_setting_keys.dart';
import 'package:argo/core/settings/settings_service.dart';
import 'package:argo/core/vehicle/vehicle_data_service.dart';
import 'package:argo/core/vehicle/vehicle_data_point.dart';
import 'package:argo/core/vehicle/vehicle_signal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../core/camera/camera_test.dart' show MemoryCameraSettings;
import 'camera_navigation_test.dart' show CameraFixture;

class NormalizedVehicle implements VehicleDataService {
  final _events = StreamController<VehicleDataPoint<Object?>>.broadcast(
    sync: true,
  );
  int _sequence = 0;
  @override
  Map<String, VehicleDataPoint<Object?>> get snapshot => {};
  @override
  VehicleDataPoint<T>? current<T>(VehicleSignal<T> signal) => null;
  @override
  Stream<VehicleDataPoint<T>> watch<T>(
    VehicleSignal<T> signal, {
    bool emitCurrent = false,
  }) => _events.stream
      .where((point) => point.key == signal.key)
      .map(
        (point) => VehicleDataPoint(
          key: point.key,
          value: signal.decode(point.value),
          timestamp: point.timestamp,
          sequence: point.sequence,
        ),
      );
  void emit<T>(VehicleSignal<T> signal, T value) {
    _events.add(
      VehicleDataPoint(
        key: signal.key,
        value: value,
        timestamp: DateTime.now(),
        sequence: ++_sequence,
      ),
    );
  }

  Future<void> close() => _events.close();
}

void main() {
  testWidgets(
    'automatic request restores only its owned navigation; manual Home cancels it',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final settings = await SettingsService.load(
        schema: AppSettingKeys.createSchema(),
        store: MemoryCameraSettings(),
      );
      final vehicle = NormalizedVehicle(), camera = CameraFixture();
      final automatic = CameraPresentationService(
        vehicle,
        policy: CameraPresentationPolicy(hold: Duration.zero),
      );
      final services = ServiceRegistry()
        ..register(settings)
        ..register<CameraService>(camera)
        ..register<CameraPresentationService>(automatic);
      final modules = AppModuleRegistry();
      for (final id in ['home', 'camera']) {
        modules.register(
          AppModule(
            id: id,
            label: id,
            icon: Icons.circle,
            builder: (_, _) => Text('$id content'),
          ),
        );
      }
      await tester.pumpWidget(
        MaterialApp(
          home: AppShell(
            environment: ArgoEnvironment(
              services: services,
              moduleRegistry: modules,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('home content'), findsOneWidget);
      vehicle.emit(CameraVehicleSignals.reverse, true);
      await tester.pumpAndSettle();
      expect(find.text('camera content'), findsOneWidget);
      vehicle.emit(CameraVehicleSignals.reverse, false);
      await tester.pumpAndSettle();
      expect(find.text('home content'), findsOneWidget);
      vehicle.emit(CameraVehicleSignals.reverse, true);
      await tester.pumpAndSettle();
      expect(find.text('camera content'), findsOneWidget);
      await tester.tap(find.byTooltip('Home'));
      await tester.pumpAndSettle();
      vehicle.emit(CameraVehicleSignals.reverse, true);
      await tester.pumpAndSettle();
      expect(find.text('home content'), findsOneWidget);
      expect(settings.get(AppSettingKeys.lastModule), 'home');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      unawaited(automatic.close());
      unawaited(vehicle.close());
      unawaited(camera.close());
      await settings.close();
      await tester.pumpAndSettle();
    },
  );
  test('steering wheel values cannot enter road-wheel overlay contract; PDC requires measured region', () {
    expect(
      () => CameraVehicleSignals.roadWheelAngle.decode(4.0),
      throwsFormatException,
    );
    expect(
      () => CameraVehicleSignals.pdcObservations.decode([
        {'distance_m': 0.3},
      ]),
      throwsFormatException,
    );
    expect(
      CameraVehicleSignals.pdcObservations.decode([
        {
          'measured_vehicle_m': [1.0, 0.2, 0.3],
          'region': 'front_left_sensor',
        },
      ]).single['measured_vehicle_m'],
      [1.0, 0.2, 0.3],
    );
  });
}
