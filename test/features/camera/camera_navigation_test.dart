import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'dart:async';

import 'package:argo/app/argo_environment.dart';
import 'package:argo/app/navigation/app_module.dart';
import 'package:argo/app/navigation/app_module_registry.dart';
import 'package:argo/app/shell/app_shell.dart';
import 'package:argo/core/camera/camera_service.dart';
import 'package:argo/core/services/service_registry.dart';
import 'package:argo/core/settings/app_setting_keys.dart';
import 'package:argo/core/settings/settings_service.dart';
import 'package:argo/features/camera/camera_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../core/camera/camera_test.dart' show MemoryCameraSettings;

class CameraFixture implements CameraService {
  final events = StreamController<CameraSnapshot>.broadcast(sync: true);
  int starts = 0, stops = 0;
  @override
  CameraSnapshot current = const CameraSnapshot(
    available: true,
    assignments: {CameraRole.rear: 'by-path:port'},
    devices: [
      CameraDevice(
        stableId: 'by-path:port',
        displayName: 'Capture',
        currentVideoNode: '/dev/video99',
      ),
    ],
  );
  @override
  Stream<CameraSnapshot> get changes => events.stream;
  @override
  Future<void> start(CameraRole role) async {
    starts++;
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> assign(CameraRole role, String stableId) async {}
  @override
  Future<void> refresh() async {}
  @override
  Future<void> close() => events.close();
}

void main() {
  testWidgets(
    'ARCV native view survives status/size changes and never receives touch',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        (call) async {
          calls.add(call);
          return call.method == 'create' ? (call.arguments as Map)['id'] : null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform_views,
          null,
        ),
      );
      final camera = CameraFixture();
      await tester.pumpWidget(
        MaterialApp(
          home: CameraActivityScope(
            active: true,
            child: CameraPage(service: camera),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'create').length, 1);
      final params =
          ((calls.firstWhere((c) => c.method == 'create').arguments
                  as Map)['params']
              as Uint8List);
      expect(params.sublist(0, 4), [65, 82, 67, 86]);
      expect(ByteData.sublistView(params).getUint32(4, Endian.little), 1);
      for (final state in [
        CameraStreamState.streaming,
        CameraStreamState.stale,
        CameraStreamState.starting,
      ]) {
        camera.current = CameraSnapshot(
          available: true,
          assignments: const {CameraRole.rear: 'by-path:port'},
          state: state,
          width: 640,
          height: 480,
        );
        camera.events.add(camera.current);
        await tester.pumpAndSettle();
      }
      await tester.tapAt(const Offset(300, 300));
      await tester.pump();
      expect(calls.where((c) => c.method == 'create').length, 1);
      expect(calls.where((c) => c.method == 'touch'), isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'dispose').length, 1);
      await camera.close();
    },
  );
  testWidgets(
    'camera entry/exit is explicit despite retained pages; remembered page never auto-starts',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final settings = await SettingsService.load(
        schema: AppSettingKeys.createSchema(),
        store: MemoryCameraSettings(),
      );
      await settings.set(AppSettingKeys.lastModule, 'camera');
      final camera = CameraFixture();
      final services = ServiceRegistry()
        ..register(settings)
        ..register<CameraService>(camera);
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
      await tester.pump(const Duration(seconds: 5));
      expect(camera.starts, 0);
      expect(find.text('home content'), findsOneWidget);
      await tester.tap(find.byTooltip('Camera'));
      await tester.pumpAndSettle();
      expect(camera.starts, 1);
      expect(find.text('camera content'), findsOneWidget);
      await tester.tap(find.byTooltip('Home'));
      await tester.pumpAndSettle();
      expect(camera.stops, 1);
      expect(find.text('camera content', skipOffstage: false), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await camera.close();
      await settings.close();
    },
  );
  testWidgets('unavailable and disconnected camera never fabricate a picture', (
    tester,
  ) async {
    final camera = CameraFixture();
    camera.current = const CameraSnapshot(error: 'No matched camera pair');
    await tester.pumpWidget(MaterialApp(home: CameraPage(service: camera)));
    expect(find.text('No matched camera pair'), findsOneWidget);
    camera.current = const CameraSnapshot(
      available: true,
      assignments: {CameraRole.rear: 'by-path:absent'},
      state: CameraStreamState.disconnected,
    );
    camera.events.add(camera.current);
    await tester.pump();
    expect(find.textContaining('disconnected'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    camera.current = const CameraSnapshot(
      available: true,
      assignments: {CameraRole.rear: 'by-path:absent'},
      state: CameraStreamState.stale,
    );
    camera.events.add(camera.current);
    await tester.pump();
    expect(find.textContaining('stale'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await camera.close();
  });
}
