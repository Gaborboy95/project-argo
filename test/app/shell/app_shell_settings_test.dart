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
import 'package:argo/core/services/service_registry.dart';
import 'package:argo/core/settings/app_setting_keys.dart';
import 'package:argo/core/settings/settings_service.dart';
import 'package:argo/core/settings/settings_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

  testWidgets('persists a module only when navigation changes', (tester) async {
    final harness = await _createHarness();
    await tester.pumpWidget(harness.widget);

    expect(harness.store.writeCount, 0);
    await tester.tap(find.byType(InkWell).at(1));
    await tester.pump();
    await harness.settings.flush();

    expect(harness.settings.get(AppSettingKeys.lastModule), 'climate');
    expect(harness.store.writeCount, 1);
    await tester.tap(find.byType(InkWell).at(1));
    await tester.pump();
    await harness.settings.flush();
    expect(harness.store.writeCount, 1);
    await harness.settings.close();
  });
}

Future<_Harness> _createHarness({String? storedModuleId}) async {
  final storedValues = <String, Object?>{};
  if (storedModuleId != null) {
    storedValues[AppSettingKeys.lastModule.id] = storedModuleId;
  }
  final store = _MemorySettingsStore(SettingsDocument(values: storedValues));
  final settings = await SettingsService.load(
    schema: AppSettingKeys.createSchema(),
    store: store,
  );
  final services = ServiceRegistry()..register(settings);
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
