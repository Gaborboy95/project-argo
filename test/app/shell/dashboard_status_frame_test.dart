import 'package:argo/app/app.dart';
import 'package:argo/app/argo_environment.dart';
import 'package:argo/app/navigation/app_module.dart';
import 'package:argo/app/navigation/app_module_registry.dart';
import 'package:argo/app/shell/dashboard_geometry.dart';
import 'package:argo/app/shell/dashboard_status_bar.dart';
import 'package:argo/core/projection/carplay_settings_service.dart';
import 'package:argo/core/projection/projection_settings_service.dart';
import 'package:argo/core/projection/projection_preferences.dart';
import 'package:argo/core/services/service_registry.dart';
import 'package:argo/core/settings/app_setting_keys.dart';
import 'package:argo/core/settings/settings_service.dart';
import 'package:argo/core/settings/settings_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'header excludes its safe area from both phone viewports exactly once and retains content on clock ticks',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(
        left: 12,
        right: 12,
        top: 24,
        bottom: 20,
      );
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetPadding);
      final settings = await SettingsService.load(
        schema: AppSettingKeys.createSchema(),
        store: _Settings(),
      );
      final aa = (await tester.runAsync(
        () async => ProjectionSettingsService(
          settings: settings,
          requested: ProjectionPreferences.defaults(),
        ),
      ))!;
      final carPlay = _CarPlayViewport();
      var contentBuilds = 0;
      final environment = ArgoEnvironment(
        services: ServiceRegistry()
          ..register(settings)
          ..register<ProjectionSettingsService>(aa)
          ..register<CarPlaySettingsService>(carPlay),
        moduleRegistry: AppModuleRegistry()
          ..register(
            AppModule(
              id: 'home',
              label: 'Home',
              icon: Icons.home,
              builder: (_, _) {
                contentBuilds++;
                return const Center(
                  key: ValueKey('retained-dashboard-content'),
                  child: Text('Dashboard fixture'),
                );
              },
            ),
          ),
      );
      tester.view.physicalSize = const Size(600, 800);
      await tester.pumpWidget(ArgoApp(environment: environment));
      await tester.pumpAndSettle();
      final content = tester.element(
        find.byKey(const ValueKey('retained-dashboard-content')),
      );
      for (final size in [
        const Size(600, 800),
        const Size(320, 426),
        const Size(800, 600),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        final bar = tester.getRect(
          find.byKey(const ValueKey('dashboard-status-bar')),
        );
        expect(bar.top, 24);
        expect(bar.left, 12);
        expect(bar.right, size.width - 12);
        expect(bar.height, DashboardStatusBar.height);
        final contentRect = tester.getRect(
          find.byKey(const ValueKey('retained-dashboard-content')),
        );
        final dock = tester.getRect(
          find.byKey(const ValueKey('fixed-dashboard-dock')),
        );
        expect(contentRect.top, bar.bottom);
        expect(dock.bottom, size.height - 20);
        expect(contentRect.bottom, dock.top);
        final geometry = DashboardGeometry(
          Size(size.width - 24, size.height - 44 - DashboardStatusBar.height),
        );
        expect(aa.measuredViewport!.$1, size.width - 24);
        expect(aa.measuredViewport!.$2, closeTo(geometry.dockTop, .001));
        expect(
          aa.measuredViewport!.$3,
          closeTo(geometry.mediaSafeHeight, .001),
        );
        expect(carPlay.viewports.last, aa.measuredViewport!);
        expect(
          tester.element(
            find.byKey(const ValueKey('retained-dashboard-content')),
          ),
          same(content),
        );
        expect(tester.takeException(), isNull);
      }
      final beforeClock = (
        contentBuilds,
        aa.measuredViewport,
        carPlay.viewports.length,
      );
      await tester.pump(const Duration(seconds: 70));
      expect((
        contentBuilds,
        aa.measuredViewport,
        carPlay.viewports.length,
      ), beforeClock);
      expect(
        tester.element(
          find.byKey(const ValueKey('retained-dashboard-content')),
        ),
        same(content),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(aa.close);
      await settings.close();
    },
  );
}

class _CarPlayViewport implements CarPlaySettingsService {
  final viewports = <(double, double, double)>[];
  @override
  void setViewport(double width, double height, double overlayHeight) =>
      viewports.add((width, height, overlayHeight));
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected CarPlay operation: ${invocation.memberName}',
  );
}

class _Settings implements SettingsStore {
  @override
  Future<SettingsDocument> read() async =>
      SettingsDocument(values: {AppSettingKeys.setupStep.id: 9});
  @override
  Future<void> write(SettingsDocument document) async {}
}
