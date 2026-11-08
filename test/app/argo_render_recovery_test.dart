import 'package:argo/app/app.dart';
import 'package:argo/app/argo_environment.dart';
import 'package:argo/app/argo_error_capture.dart';
import 'package:argo/app/argo_render_recovery.dart';
import 'package:argo/app/navigation/app_module.dart';
import 'package:argo/app/navigation/app_module_registry.dart';
import 'package:argo/core/diagnostics/diagnostics_service.dart';
import 'package:argo/core/services/service_registry.dart';
import 'package:argo/core/settings/app_setting_keys.dart';
import 'package:argo/core/settings/settings_service.dart';
import 'package:argo/core/settings/settings_store.dart';
import 'package:argo/features/projection/projection_input_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'a failed destination can return Home without changing saved choices',
    (tester) async {
      final settings = await SettingsService.load(
        schema: AppSettingKeys.createSchema(),
        store: _Store(),
      );
      await settings.set(AppSettingKeys.lastModule, 'settings');
      final diagnostics = DiagnosticsService();
      final oldErrorBuilder = ErrorWidget.builder;
      final capture = ArgoErrorCapture.install(diagnostics);
      final environment = ArgoEnvironment(
        services: ServiceRegistry()..register(settings),
        moduleRegistry: AppModuleRegistry()
          ..register(
            AppModule(
              id: 'home',
              label: 'Home',
              icon: Icons.home,
              builder: (_, _) => const Center(child: Text('Recovered Home')),
            ),
          )
          ..register(
            AppModule(
              id: 'settings',
              label: 'Settings',
              icon: Icons.settings,
              builder: (context, _) {
                if (ProjectionInputScope.activeOf(context)) {
                  throw StateError('synthetic failing destination');
                }
                return const SizedBox();
              },
            ),
          ),
      );
      await tester.pumpWidget(ArgoApp(environment: environment));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isA<StateError>());
      expect(find.text('This view could not be displayed.'), findsOneWidget);
      expect(diagnostics.latest?.source, 'flutter.framework');
      await tester.tap(
        find.byKey(const ValueKey('render-failure-return-home')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Recovered Home').hitTestable(), findsOneWidget);
      expect(find.byType(ArgoRenderFailure), findsNothing);
      expect(settings.get(AppSettingKeys.lastModule), 'settings');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      capture.restore();
      expect(ErrorWidget.builder, same(oldErrorBuilder));
      await settings.close();
    },
  );

  testWidgets(
    'failure view fits tiny and unbounded slots without Material dependencies',
    (tester) async {
      for (final size in [
        const Size(24, 24),
        const Size(320, 240),
        const Size(800, 600),
      ]) {
        var recovered = false;
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: ArgoRenderRecoveryScope(
              returnHome: () => recovered = true,
              child: Center(
                child: SizedBox(
                  width: size.width,
                  height: size.height,
                  child: const ArgoRenderFailure(),
                ),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        await tester.tap(
          find.byKey(const ValueKey('render-failure-return-home')),
        );
        expect(recovered, isTrue);
      }
      await tester.pumpWidget(
        const UnconstrainedBox(child: ArgoRenderFailure()),
      );
      expect(tester.takeException(), isNull);
    },
  );
}

class _Store implements SettingsStore {
  @override
  Future<SettingsDocument> read() async => SettingsDocument();
  @override
  Future<void> write(SettingsDocument document) async {}
}
