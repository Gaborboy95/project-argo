import 'package:argo/core/climate/climate_service.dart';

import 'dart:async';

import 'package:argo/core/diagnostics/diagnostics_service.dart';
import 'package:argo/core/projection/projection_preferences.dart';
import 'package:argo/core/projection/projection_configuration.dart';
import 'package:argo/core/projection/projection_settings_service.dart';
import 'package:argo/features/settings/projection_settings_card.dart';
import 'package:argo/app/argo_environment.dart';
import 'package:argo/app/navigation/app_module.dart';
import 'package:argo/app/navigation/app_module_registry.dart';
import 'package:argo/app/shell/app_shell.dart';
import 'package:argo/app/shell/dashboard_panel.dart';
import 'package:argo/app/shell/dashboard_geometry.dart';
import 'package:argo/core/services/service_registry.dart';
import 'package:argo/core/settings/app_setting_keys.dart';
import 'package:argo/core/settings/settings_service.dart';
import 'package:argo/core/settings/settings_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('portrait allocates a tall projection and a bounded media strip', () {
    for (final size in [
      const Size(768, 1024),
      const Size(600, 800),
      const Size(320, 426),
      const Size(1200, 1600),
    ]) {
      final geometry = DashboardGeometry(size);
      expect(geometry.closedMediaHeight, 96);
      expect(geometry.primaryHeight, greaterThan(size.width * 9 / 16));
      expect(geometry.dockHeight, lessThanOrEqualTo(160));
      expect(
        geometry.primaryHeight +
            geometry.closedMediaHeight +
            2 * DashboardGeometry.mediaEdgeGap +
            geometry.dockHeight,
        size.height,
      );
    }
    final landscape = DashboardGeometry(const Size(1024, 768));
    expect(landscape.dockHeight, closeTo(138.24, .001));
    expect(landscape.closedMediaHeight, 96);
    final short = DashboardGeometry(const Size(320, 240));
    expect(short.closedMediaHeight, closeTo(short.dockTop * .35, .001));
    expect(short.closedMediaHeight, lessThan(96));
    expect(DashboardGeometry(const Size(1000, 900)).closedMediaHeight, 96);
  });

  testWidgets(
    'portrait keeps essential dock actions visible inside safe area',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(
        left: 12,
        right: 12,
        top: 24,
        bottom: 20,
      );
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final size in [
        const Size(768, 1024),
        const Size(600, 800),
        const Size(320, 426),
      ]) {
        final harness = await _createHarness(controlSize: 1.3);
        tester.view.physicalSize = size;
        await tester.pumpWidget(harness.widget);
        await tester.pumpAndSettle();
        final safe = Rect.fromLTRB(12, 24, size.width - 12, size.height - 20);
        final dock = tester.getRect(
          find.byKey(const ValueKey('fixed-dashboard-dock')),
        );
        expect(safe.contains(dock.topLeft), isTrue);
        expect(dock.bottom, safe.bottom);
        for (final label in [
          'Home',
          'Apps',
          'Settings',
          'Media strip',
          'Camera',
        ]) {
          final control = tester.getRect(find.byTooltip(label));
          expect(control.left, greaterThanOrEqualTo(safe.left));
          expect(control.right, lessThanOrEqualTo(safe.right));
        }
        expect(
          tester
              .getSize(find.byKey(const ValueKey('floating-media-surface')))
              .height,
          DashboardGeometry(Size(size.width - 24, size.height - 44))
              .closedMediaHeight,
        );
        expect(find.byTooltip('Left warmer'), findsNothing);
        final temperature = find.byKey(const ValueKey('temperature-Left'));
        expect(tester.getSize(temperature).height, greaterThanOrEqualTo(48));
        await tester.tap(temperature);
        await tester.pumpAndSettle();
        expect(find.byTooltip('Close climate').hitTestable(), findsOneWidget);
        expect(find.byTooltip('Left warmer'), findsOneWidget);
        expect(find.byTooltip('Left cooler').hitTestable(), findsOneWidget);
        await tester.tap(find.byTooltip('Close climate'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Apps'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('Close apps'), findsOneWidget);
        expect(find.text('climate').hitTestable(), findsOneWidget);
        if (size.width < 400) {
          await tester.drag(find.byType(DashboardPanel), const Offset(0, -240));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.text('climate'));
        await tester.pumpAndSettle();
        expect(find.text('climate page'), findsOneWidget);
        await tester.tap(find.byTooltip('Home'));
        await tester.pumpAndSettle();
        expect(find.text('home page'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await harness.settings.close();
      }
    },
  );

  testWidgets(
    'short landscape windows retain a scrollable dock and modal dismissal',
    (tester) async {
      final harness = await _createHarness();
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      for (final size in [
        const Size(640, 360),
        const Size(480, 320),
        const Size(320, 240),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpWidget(harness.widget);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('temperature-Left')));
        await tester.pumpAndSettle();
        expect(
          find.text('Simulated feedback — no vehicle actuation'),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('Close climate'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
      await harness.settings.close();
    },
  );

  testWidgets(
    'open panels survive landscape to portrait resize with large controls',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 600);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final harness = await _createHarness(controlSize: 1.3);
      await tester.pumpWidget(harness.widget);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('temperature-Left')));
      await tester.pumpAndSettle();
      final panel = tester.element(find.byType(DashboardPanel));
      for (final size in [
        const Size(600, 800),
        const Size(320, 426),
        const Size(800, 600),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(tester.element(find.byType(DashboardPanel)), same(panel));
        expect(find.byTooltip('Close climate').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.byTooltip('Close climate'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Expand media'));
      await tester.pumpAndSettle();
      final surface = tester.element(
        find.byKey(const ValueKey('floating-media-surface')),
      );
      for (final size in [
        const Size(600, 800),
        const Size(320, 426),
        const Size(800, 600),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(
          tester.element(find.byKey(const ValueKey('floating-media-surface'))),
          same(surface),
        );
        expect(find.byTooltip('Close media').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.byTooltip('Close media'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await harness.settings.close();
    },
  );

  testWidgets(
    'projection editor recovers saved pairs and persists pending requests without changing active',
    (tester) async {
      final store = _MemorySettingsStore(
        SettingsDocument(
          values: {AppSettingKeys.projectionDisplayWidth.id: 801},
        ),
      );
      final settings = await SettingsService.load(
        schema: AppSettingKeys.createSchema(),
        store: store,
      );
      final diagnostics = DiagnosticsService();
      final initial = await ProjectionSettingsService.load(
        settings,
        diagnostics,
      );
      expect(initial, ProjectionPreferences.defaults());
      expect(diagnostics.latest?.message, contains('unsupported'));
      final backend = _ConfigurationBackend(initial);
      final service = ProjectionSettingsService(
        settings: settings,
        requested: initial,
        backend: backend,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ProjectionSettingsCard(service: service),
            ),
          ),
        ),
      );
      expect(find.text('Current session selected: $initial'), findsOneWidget);
      final dpi = find.byKey(const ValueKey('projection-dpi-160'));
      await tester.ensureVisible(dpi);
      await tester.enterText(dpi, '180');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(service.requested.dpi, 180);
      expect(backend.configuration.pending?.dpi, 180);
      expect(backend.configuration.active?.dpi, 160);
      expect(
        find.textContaining('Applies on next phone connection'),
        findsOneWidget,
      );
      final reopened = await SettingsService.load(
        schema: AppSettingKeys.createSchema(),
        store: store,
      );
      expect(ProjectionPreferences.fromSettings(reopened).dpi, 180);
      await tester.enterText(
        find.byKey(const ValueKey('projection-dpi-180')),
        '79',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(service.requested.dpi, 180);
      expect(find.text('Enter DPI within 80–640'), findsOneWidget);
      backend.unavailable();
      await tester.pump();
      expect(
        find.textContaining('Saved preferences remain visible'),
        findsOneWidget,
      );
      await service.reset();
      await tester.pump();
      expect(service.requested, initial);
      expect(service.notice, contains('not validated'));
      await tester.pumpWidget(const SizedBox());
      // Complete stream shutdown outside the widget test's fake clock.
      await tester.runAsync(service.close);
      await backend.close();
      await settings.close();
      await reopened.close();
    },
  );

  testWidgets('restores the last selected module by stable ID', (tester) async {
    final harness = await _createHarness(storedModuleId: 'climate');

    await tester.pumpWidget(harness.widget);

    expect(tester.widget<IndexedStack>(find.byType(IndexedStack)).index, 1);
    expect(find.text('climate page'), findsOneWidget);
    await harness.settings.close();
  });

  for (final storedModuleId in <String?>['removed-module', null]) {
    final description = storedModuleId == null ? 'missing' : 'invalid';
    testWidgets('$description stored module falls back to Home', (
      tester,
    ) async {
      final harness = await _createHarness(storedModuleId: storedModuleId);

      await tester.pumpWidget(harness.widget);

      expect(tester.widget<IndexedStack>(find.byType(IndexedStack)).index, 0);
      expect(find.text('home page'), findsOneWidget);
      await harness.settings.close();
    });
  }

  testWidgets('dock replaces panels and the same temperature toggles climate', (
    tester,
  ) async {
    final harness = await _createHarness();
    await tester.pumpWidget(harness.widget);
    final floating = find.byKey(const ValueKey('floating-media-surface'));
    final element = tester.element(floating);
    final collapsed = tester.getSize(floating).height;
    final drag = await tester.startGesture(
      tester.getCenter(find.byTooltip('Expand media')),
    );
    await drag.moveBy(const Offset(0, -60));
    await tester.pump();
    expect(tester.element(floating), same(element));
    expect(tester.getSize(floating).height, closeTo(collapsed + 60, .001));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.getSize(floating).height, closeTo(collapsed + 60, .001));
    await drag.moveBy(const Offset(0, -240));
    await drag.up();
    await tester.pumpAndSettle();
    expect(find.byTooltip('Close media'), findsOneWidget);
    await tester.tap(find.byTooltip('Apps'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Close media'), findsNothing);
    expect(find.byType(DashboardPanel), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('temperature-Left')).last);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Close apps'), findsNothing);
    expect(find.byTooltip('Close climate'), findsOneWidget);
    expect(find.byType(DashboardPanel), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('temperature-Left')).last);
    await tester.pumpAndSettle();
    expect(find.byType(DashboardPanel), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await harness.settings.close();
  });

  testWidgets('persists a module only when navigation changes', (tester) async {
    final harness = await _createHarness();
    await tester.pumpWidget(harness.widget);

    expect(harness.store.writeCount, 0);
    await tester.tap(find.byTooltip('Apps'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('climate'));
    await tester.pump();
    await harness.settings.flush();

    expect(harness.settings.get(AppSettingKeys.lastModule), 'climate');
    expect(harness.store.writeCount, 1);
    await tester.tap(find.byTooltip('Apps'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('climate'));
    await tester.pump();
    await harness.settings.flush();
    expect(harness.store.writeCount, 1);
    await harness.settings.close();
  });
}

Future<_Harness> _createHarness({
  String? storedModuleId,
  double controlSize = 1,
}) async {
  final storedValues = <String, Object?>{
    AppSettingKeys.appearanceControlSize.id: controlSize,
  };
  if (storedModuleId != null) {
    storedValues[AppSettingKeys.lastModule.id] = storedModuleId;
  }
  final store = _MemorySettingsStore(SettingsDocument(values: storedValues));
  final settings = await SettingsService.load(
    schema: AppSettingKeys.createSchema(),
    store: store,
  );
  final climate = VehicleClimateService(
    capabilities: ClimateCapabilities.simulation(),
    simulated: true,
    publish: (_) async {},
    authorize: (_) async => true,
    diagnostics: DiagnosticsService(),
  );
  climate.invalidate(available: true);
  addTearDown(climate.close);
  final services = ServiceRegistry()
    ..register(settings)
    ..register<ClimateService>(climate);
  final modules = AppModuleRegistry()
    ..register(_module('home'))
    ..register(_module('climate'));
  final environment = ArgoEnvironment(
    services: services,
    moduleRegistry: modules,
  );

  return _Harness(
    widget: MaterialApp(home: AppShell(environment: environment)),
    settings: settings,
    store: store,
  );
}

AppModule _module(String id) => AppModule(
  id: id,
  label: id,
  icon: Icons.circle_outlined,
  builder: (_, _) => Center(child: Text('$id page')),
);

final class _Harness {
  const _Harness({
    required this.widget,
    required this.settings,
    required this.store,
  });

  final Widget widget;
  final SettingsService settings;
  final _MemorySettingsStore store;
}

final class _MemorySettingsStore implements SettingsStore {
  _MemorySettingsStore(this.document);

  SettingsDocument document;
  var writeCount = 0;

  @override
  Future<SettingsDocument> read() async => document;

  @override
  Future<void> write(SettingsDocument nextDocument) async {
    writeCount++;
    document = nextDocument;
  }
}

final class _ConfigurationBackend implements ProjectionConfigurationBackend {
  _ConfigurationBackend(ProjectionPreferences initial)
    : configuration = ProjectionConfigurationState(
        readiness: ProjectionReadiness.ready,
        message: 'Ready',
        pending: initial,
        active: initial,
        sessionId: 'phone',
        capabilities: ProjectionCapabilities(
          resolutions: const [(1280, 720)],
          frameRates: const [30],
          minimumDpi: 80,
          maximumDpi: 640,
          defaults: initial,
          audio: const [ProjectionAudioFormat('Media', 48000, 16, 2)],
        ),
      );
  @override
  ProjectionConfigurationState configuration;
  final _changes = StreamController<ProjectionConfigurationState>.broadcast(
    sync: true,
  );
  @override
  Stream<ProjectionConfigurationState> get configurationChanges =>
      _changes.stream;
  @override
  Future<void> requestConfiguration(ProjectionPreferences p) async {
    configuration = ProjectionConfigurationState(
      readiness: configuration.readiness,
      message: 'Ready',
      capabilities: configuration.capabilities,
      pending: p,
      active: configuration.active,
      sessionId: 'phone',
      revision: configuration.revision + 1,
    );
    _changes.add(configuration);
  }

  void unavailable() {
    configuration = const ProjectionConfigurationState();
    _changes.add(configuration);
  }

  Future<void> close() => _changes.close();
}
