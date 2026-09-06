import 'package:argo/app/app.dart';
import 'package:argo/app/argo_environment.dart';
import 'package:argo/app/navigation/app_module.dart';
import 'package:argo/app/navigation/app_module_registry.dart';
import 'package:argo/core/services/service_registry.dart';
import 'package:argo/core/settings/app_setting_keys.dart';
import 'package:argo/core/settings/settings_service.dart';
import 'package:argo/core/settings/settings_store.dart';
import 'package:argo/features/settings/appearance_settings_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'appearance persists, recovers invalid values and resets only appearance',
    (tester) async {
      final store = _Store()
        ..document = SettingsDocument(
          values: {
            'appearance.themeMode': 'headlights',
            'appearance.seedColor': '#123',
            'audio.master.volume': 0.7,
            'projection.display.dpi': 180,
            'app.navigation.lastModule': 'media',
          },
        );
      final diagnostics = <SettingsDiagnostic>[];
      var settings = await SettingsService.load(
        schema: AppSettingKeys.createSchema(),
        store: store,
        onDiagnostic: diagnostics.add,
      );
      expect(diagnostics, hasLength(2));
      expect(settings.get(AppSettingKeys.appearanceThemeMode), 'dark');
      expect(settings.get(AppSettingKeys.appearanceSeedColor), '#6750A4');
      await settings.set(AppSettingKeys.appearanceThemeMode, 'light');
      await settings.set(AppSettingKeys.appearanceSeedColor, '#006a6a');
      await settings.close();
      settings = await SettingsService.load(
        schema: AppSettingKeys.createSchema(),
        store: store,
      );
      expect(settings.get(AppSettingKeys.appearanceThemeMode), 'light');
      expect(settings.get(AppSettingKeys.appearanceSeedColor), '#006A6A');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AppearanceSettingsCard(settings: settings)),
        ),
      );
      await tester.tap(find.text('Reset appearance to defaults'));
      await tester.pumpAndSettle();
      expect(settings.get(AppSettingKeys.appearanceThemeMode), 'dark');
      expect(settings.get(AppSettingKeys.appearanceSeedColor), '#6750A4');
      expect(settings.get(AppSettingKeys.audioMasterVolume), 0.7);
      expect(settings.get(AppSettingKeys.projectionDisplayDpi), 180);
      expect(settings.get(AppSettingKeys.lastModule), 'media');
      await tester.pumpWidget(const SizedBox());
      await settings.close();
    },
  );

  testWidgets(
    'manual theme and accent apply immediately; system follows Flutter brightness',
    (tester) async {
      final settings = await SettingsService.load(
        schema: AppSettingKeys.createSchema(),
        store: _Store(),
      );
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final environment = ArgoEnvironment(
        services: ServiceRegistry()..register(settings),
        moduleRegistry: AppModuleRegistry()
          ..register(
            AppModule(
              id: 'home',
              label: 'Home',
              icon: Icons.home,
              builder: (_, _) => AppearanceSettingsCard(settings: settings),
            ),
          ),
      );
      await tester.pumpWidget(ArgoApp(environment: environment));
      await tester.pumpAndSettle();
      ThemeData theme() =>
          Theme.of(tester.element(find.byType(AppearanceSettingsCard)));
      expect(theme().brightness, Brightness.dark);
      expect(
        theme().colorScheme,
        ThemeData(brightness: Brightness.dark, useMaterial3: true).colorScheme,
      );
      // Exercise the actual settings control, not just ThemeData construction.
      await tester.tap(find.text('Dark'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Light').last);
      await tester.pumpAndSettle();
      expect(settings.get(AppSettingKeys.appearanceThemeMode), 'light');
      expect(theme().brightness, Brightness.light);
      final primary = theme().colorScheme.primary;
      await settings.set(AppSettingKeys.appearanceSeedColor, '#006A6A');
      await tester.pumpAndSettle();
      expect(theme().colorScheme.primary, isNot(primary));
      await settings.set(AppSettingKeys.appearanceThemeMode, 'system');
      await tester.pumpAndSettle();
      expect(theme().brightness, Brightness.light);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();
      expect(theme().brightness, Brightness.dark);
      await settings.set(AppSettingKeys.appearanceThemeMode, 'light');
      await tester.pumpAndSettle();
      expect(theme().brightness, Brightness.light);
      await tester.pumpWidget(const SizedBox());
      await settings.close();
    },
  );
}

class _Store implements SettingsStore {
  SettingsDocument document = SettingsDocument();
  @override
  Future<SettingsDocument> read() async => document;
  @override
  Future<void> write(SettingsDocument value) async {
    document = value;
  }
}
