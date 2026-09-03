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
  builder: (_) => Center(child: Text('$id page')),
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
