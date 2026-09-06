import 'package:argo/app/projection_composition.dart';
import 'package:argo/core/audio/audio_service.dart';
import 'package:argo/core/audio/in_memory_audio_backend.dart';
import 'package:argo/core/diagnostics/diagnostics_service.dart';
import 'package:argo/core/lifecycle/app_lifecycle_coordinator.dart';
import 'package:argo/core/projection/projection_backend.dart';
import 'package:argo/core/projection/projection_service.dart';
import 'package:argo/core/projection/disabled_projection_backend.dart';
import 'package:argo/core/projection/projection_render_test.dart';
import 'package:argo/features/media/media_page.dart';
import 'package:argo/features/projection/projection_view.dart';
import 'package:argo/integrations/projection/ihs_projection_view_registry.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:argo/core/services/service_registry.dart';
import 'package:argo/core/settings/app_setting_keys.dart';
import 'package:argo/core/settings/settings_service.dart';
import 'package:argo/core/settings/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('renderer diagnostic is opt-in and rejects a real backend', () {
    for (final value in [null, '0']) {
      expect(
        ProjectionRenderTest.fromEnvironment({
          'ARGO_PROJECTION_RENDER_TEST': ?value,
          'ARGO_PROJECTION_BACKEND': 'android-auto',
        }).enabled,
        isFalse,
      );
    }
    expect(
      ProjectionRenderTest.fromEnvironment(const {
        'ARGO_PROJECTION_RENDER_TEST': '1',
        'ARGO_PROJECTION_BACKEND': 'disabled',
      }).enabled,
      isTrue,
    );
    expect(
      () => ProjectionRenderTest.fromEnvironment(const {
        'ARGO_PROJECTION_RENDER_TEST': '1',
        'ARGO_PROJECTION_BACKEND': 'android-auto',
      }),
      throwsArgumentError,
    );
  });

  testWidgets('renderer diagnostic creates existing view without AA', (
    tester,
  ) async {
    late SettingsService settings;
    late AudioService audio;
    late ProjectionService projection;
    final services = ServiceRegistry();
    final lifecycle = AppLifecycleCoordinator();
    final registry = _ViewRegistry();
    var registrations = 0;
    await tester.runAsync(() async {
      settings = await SettingsService.load(
        schema: AppSettingKeys.createSchema(),
        store: _MemoryStore(),
      );
      audio = await DefaultAudioService.start(
        backend: InMemoryAudioBackend(),
        settings: settings,
        diagnostics: DiagnosticsService(),
      );
      services
        ..register(settings)
        ..register<AudioService>(audio);
      projection = await registerProjectionServices(
        services: services,
        lifecycle: lifecycle,
        diagnostics: DiagnosticsService(),
        environment: const {
          'ARGO_PROJECTION_RENDER_TEST': '1',
          'ARGO_PROJECTION_BACKEND': 'disabled',
          'ARGO_PROJECTION_SOCKET': '/must-not-connect',
          'ARGO_PROJECTION_MEDIA_SOCKET': '/must-not-connect-video',
        },
        isLinux: true,
        transportFactory: (_) => throw StateError('Must not contact AA daemon'),
        viewRegistryLoader: ({libraryPath}) {
          registrations++;
          return registry;
        },
      );
    });
    expect(registrations, 1);
    expect(services.get<ProjectionBackend>(), isA<DisabledProjectionBackend>());
    expect(projection.current.backendAvailable, isFalse);
    expect(projection.current.sessions, isEmpty);
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
    await tester.pumpWidget(
      MaterialApp(
        home: MediaPage(
          projection: projection,
          rendererTest: services.get<ProjectionRenderTest>().enabled,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Native renderer test — no phone'), findsOneWidget);
    expect(find.byType(ProjectionView), findsOneWidget);
    expect(find.byType(PlatformViewSurface), findsOneWidget);
    final create = calls.singleWhere((call) => call.method == 'create');
    expect((create.arguments as Map)['viewType'], ProjectionView.viewType);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(calls.any((call) => call.method == 'dispose'), isTrue);
    await tester.runAsync(() async {
      await lifecycle.shutdown();
      expect(registry.closed, isTrue);
      await audio.close();
      await settings.close();
    });
  });

  test('registers disabled projection and lifecycle cleans it up', () async {
    final settings = await SettingsService.load(
      schema: AppSettingKeys.createSchema(),
      store: _MemoryStore(),
    );
    final audio = await DefaultAudioService.start(
      backend: InMemoryAudioBackend(),
      settings: settings,
      diagnostics: DiagnosticsService(),
    );
    final services = ServiceRegistry()
      ..register(settings)
      ..register<AudioService>(audio);
    final lifecycle = AppLifecycleCoordinator();

    final projection = await registerProjectionServices(
      services: services,
      lifecycle: lifecycle,
      diagnostics: DiagnosticsService(),
      environment: const {},
      isLinux: false,
    );

    expect(services.get<ProjectionService>(), same(projection));
    expect(services.contains<ProjectionBackend>(), isTrue);
    await lifecycle.shutdown();
    await audio.close();
    await settings.close();
  });
}

final class _MemoryStore implements SettingsStore {
  var document = SettingsDocument();
  @override
  Future<SettingsDocument> read() async => document;
  @override
  Future<void> write(SettingsDocument document) async =>
      this.document = document;
}

final class _ViewRegistry implements ProjectionViewRegistry {
  bool closed = false;
  @override
  Future<void> close() async {
    closed = true;
  }
}
