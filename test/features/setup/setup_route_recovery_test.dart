import 'dart:io';

import 'package:argo/app/app.dart';
import 'package:argo/app/argo_environment.dart';
import 'package:argo/app/navigation/app_module.dart';
import 'package:argo/app/navigation/app_module_registry.dart';
import 'package:argo/core/audio/audio_service.dart';
import 'package:argo/core/diagnostics/diagnostics_service.dart';
import 'package:argo/core/services/service_registry.dart';
import 'package:argo/core/settings/app_setting_keys.dart';
import 'package:argo/core/settings/settings_service.dart';
import 'package:argo/core/settings/settings_store.dart';
import 'package:argo/features/settings/settings_page.dart';
import 'package:argo/features/setup/setup_assistant.dart';
import 'package:argo/features/setup/touch_check.dart';
import 'package:argo/integrations/audio/pipewire_audio_backend.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('display setup works when host display identity is unavailable', (
    tester,
  ) async {
    final fixture = await _Fixture.create(1);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 1600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final display = _UnavailableDisplay(
      tester.platformDispatcher,
      tester.view.display,
    );
    final view = TestFlutterView(
      view: tester.view,
      platformDispatcher: tester.platformDispatcher,
      display: display,
    );
    await tester.pumpWidget(
      View(
        view: view,
        child: ArgoApp(environment: fixture.environment),
      ),
      wrapWithView: false,
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Current viewport 1200 × 1600 logical pixels'),
      findsOneWidget,
    );
    expect(display.identityReads, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await fixture.close(tester);
  });

  testWidgets('expanded audio details cannot replace section scroll offsets', (
    tester,
  ) async {
    final fixture = await _Fixture.create(9);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 1600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(ArgoApp(environment: fixture.environment));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Details').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Appearance').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sound').first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Selected audio output is unavailable'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await fixture.close(tester);
  });

  for (var step = 0; step < 9; step++) {
    testWidgets(
      'real dark application resumes and closes setup route at saved step $step',
      (tester) async {
        final fixture = await _Fixture.create(step);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1200, 1600);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await tester.pumpWidget(ArgoApp(environment: fixture.environment));
        await tester.pumpAndSettle();
        expect(find.byType(SetupAssistant), findsOneWidget);
        expect(find.text('Step ${step + 1} of 9'), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (step == 1) {
          await tester.tap(find.text('Test screen corners'));
          await tester.pumpAndSettle();
          expect(find.byType(TouchCheck), findsOneWidget);
          for (var corner = 0; corner < 4; corner++) {
            await tester.tap(find.byKey(ValueKey('touch-corner-$corner')));
            await tester.pump();
          }
          await tester.tap(find.text('Touch confirmed'));
          await tester.pumpAndSettle();
          expect(find.byType(TouchCheck), findsNothing);
          expect(find.text('Touch confirmed'), findsOneWidget);
        }
        if (step == 8) {
          await tester.tap(find.widgetWithText(FilledButton, 'Finish'));
          await tester.pumpAndSettle();
          expect(fixture.settings.get(AppSettingKeys.setupStep), 9);
        } else {
          await tester.tap(find.byTooltip('Back'));
          await tester.pumpAndSettle();
        }
        expect(find.byType(SetupAssistant), findsNothing);
        expect(find.byType(SettingsPage), findsOneWidget);
        await tester.tap(find.text('System').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Setup assistant'));
        await tester.pumpAndSettle();
        expect(find.byType(SetupAssistant), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await fixture.close(tester);
      },
    );
  }
}

class _Fixture {
  _Fixture(this.settings, this.audio, this.environment);
  final SettingsService settings;
  final AudioService audio;
  final ArgoEnvironment environment;
  static Future<_Fixture> create(int step) async {
    final settings = await SettingsService.load(
      schema: AppSettingKeys.createSchema(),
      store: _Store(step),
    );
    final audio = await DefaultAudioService.start(
      backend: PipeWireAudioBackend(
        processRunner: (exe, args) async => ProcessResult(
          1,
          0,
          exe == 'pw-dump'
              ? '[]'
              : args.first == 'get-volume'
              ? 'Volume: 0.25'
              : '',
          '',
        ),
      ),
      settings: settings,
      diagnostics: DiagnosticsService(),
    );
    final services = ServiceRegistry()
      ..register(settings)
      ..register<AudioService>(audio);
    final modules = AppModuleRegistry()
      ..register(
        AppModule(
          id: 'home',
          label: 'Home',
          icon: Icons.home_outlined,
          builder: (_, _) => const Center(child: Text('Host home')),
        ),
      )
      ..register(
        AppModule(
          id: 'settings',
          label: 'Settings',
          icon: Icons.settings_outlined,
          builder: (_, _) => SettingsPage(audio: audio, settings: settings),
        ),
      );
    return _Fixture(
      settings,
      audio,
      ArgoEnvironment(services: services, moduleRegistry: modules),
    );
  }

  Future<void> close(WidgetTester tester) async {
    await tester.runAsync(audio.close);
    await settings.close();
  }
}

class _Store implements SettingsStore {
  _Store(int step)
    : document = SettingsDocument(
        values: {
          AppSettingKeys.setupStep.id: step,
          AppSettingKeys.appearanceThemeMode.id: 'dark',
          AppSettingKeys.appearanceControlSize.id: 1.15,
          AppSettingKeys.lastModule.id: 'settings',
          AppSettingKeys.audioPreferredOutput.id: 'missing.output',
        },
      );
  SettingsDocument document;
  @override
  Future<SettingsDocument> read() async => document;
  @override
  Future<void> write(SettingsDocument document) async =>
      this.document = document;
}

class _UnavailableDisplay extends TestDisplay {
  _UnavailableDisplay(super.platformDispatcher, super.display);
  var identityReads = 0;
  @override
  int get id {
    identityReads++;
    throw StateError('Host did not publish matching display metadata');
  }
}
