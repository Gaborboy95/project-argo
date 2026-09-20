import '../core/projection/carplay_settings_service.dart';
import '../core/projection/multiplex_projection_backend.dart';
import '../integrations/projection/carplay_projection_backend.dart';
import '../core/projection/carplay_link_diagnostics.dart';
import '../integrations/projection/carplay_link_diagnostics_client.dart';
import '../integrations/bluetooth/bluetooth_call_audio.dart';

import 'dart:io';

import '../integrations/projection/android_auto_projection_backend.dart';
import '../integrations/projection/projection_endpoints.dart';
import '../integrations/bluetooth/bluetooth_media_source.dart';
import '../core/connectivity/connectivity_preferences.dart';
import '../core/connectivity/connectivity_service.dart';
import '../core/media/media_session_service.dart';
import '../integrations/projection/projection_media_source.dart';
import '../core/audio/audio_service.dart';
import '../core/diagnostics/diagnostics_service.dart';
import '../core/lifecycle/app_lifecycle_coordinator.dart';
import '../core/projection/projection_backend.dart';
import '../core/projection/projection_backend_type.dart';
import '../core/projection/projection_settings_service.dart';
import '../core/projection/projection_configuration.dart';
import '../core/projection/projection_presentation_options.dart';
import '../core/projection/projection_render_test.dart';
import '../core/projection/projection_service.dart';
import '../core/services/service_registry.dart';
import '../core/settings/settings_service.dart';
import '../integrations/projection/projection_backend_selection.dart';
import '../integrations/projection/ihs_projection_view_registry.dart';
import '../integrations/projection/projection_ipc.dart';

Future<ProjectionService> registerProjectionServices({
  required ServiceRegistry services,
  required AppLifecycleCoordinator lifecycle,
  required DiagnosticsService diagnostics,
  required Map<String, String> environment,
  bool? isLinux,
  ProjectionControlTransportFactory? transportFactory,
  ProjectionViewRegistry Function({String? libraryPath})? viewRegistryLoader,
}) async {
  final carPlayEnabled = environment['ARGO_CARPLAY_ENABLED'] == '1';
  if (carPlayEnabled &&
      (!(isLinux ?? Platform.isLinux) ||
          environment['ARGO_PROJECTION_RENDER_TEST'] == '1')) {
    throw ArgumentError(
      'Native CarPlay requires a normal Linux projection session.',
    );
  }
  final carPlayDiagnostics = environment['ARGO_CARPLAY_DIAGNOSTICS'];
  if (carPlayDiagnostics != null &&
      carPlayDiagnostics != '0' &&
      carPlayDiagnostics != '1') {
    throw ArgumentError('ARGO_CARPLAY_DIAGNOSTICS must be 0 or 1.');
  }
  if (carPlayDiagnostics == '1' || carPlayEnabled) {
    if (!(isLinux ?? Platform.isLinux)) {
      throw UnsupportedError('LIVI Link diagnostics require Linux.');
    }
    final runtime = environment['XDG_RUNTIME_DIR'];
    if (runtime == null || !runtime.startsWith('/') || runtime.endsWith('/')) {
      throw ArgumentError(
        'LIVI Link diagnostics require an absolute XDG_RUNTIME_DIR.',
      );
    }
    final health = CarPlayLinkDiagnosticsClient(
      socketPath: '$runtime/project-argo/carplay.sock',
    );
    lifecycle.registerShutdown(
      name: 'carplay.diagnostics',
      phase: AppShutdownPhase.stopActivity,
      shutdown: health.close,
    );
    services.register<CarPlayLinkDiagnostics>(health);
    health.start();
  }
  final renderTest = ProjectionRenderTest.fromEnvironment(environment);
  final preferences = await ProjectionSettingsService.load(
    services.get<SettingsService>(),
    diagnostics,
  );
  final backend = await selectProjectionBackend(
    environment: environment,
    preferences: preferences,
    diagnostics: diagnostics,
    isLinux: isLinux,
    transportFactory: transportFactory,
  );
  ConnectivityService? connectivity;
  if (backend is ConnectivityService) {
    connectivity = backend as ConnectivityService;
  } else if (isLinux ?? Platform.isLinux) {
    final standalone = AndroidAutoProjectionBackend(
      socketPath: projectionEndpoint(
        environment,
        'ARGO_PROJECTION_SOCKET',
        'projection.sock',
      ),
      preferences: preferences,
      diagnostics: diagnostics,
      transportFactory: transportFactory,
      connectivityOnly: true,
    );
    await standalone.start();
    connectivity = standalone;
    lifecycle.registerShutdown(
      name: 'connectivity.client',
      phase: AppShutdownPhase.stopActivity,
      shutdown: standalone.close,
    );
  }
  if (connectivity != null) {
    final configured = ConnectivityPreferences(
      connectivity,
      services.get<SettingsService>(),
      diagnostics: diagnostics,
      projectionConfigured:
          ProjectionBackendType.fromEnvironment(environment) ==
          ProjectionBackendType.androidAuto,
      startupConnections: (environment['ARGO_STARTUP_CONNECTIONS'] ?? '')
          .split(',')
          .where({'wireless', 'music', 'calls'}.contains)
          .toSet(),
    );
    services.register<ConnectivityService>(configured);
    lifecycle.registerShutdown(
      name: 'connectivity.preferences',
      phase: AppShutdownPhase.stopActivity,
      shutdown: configured.close,
    );
  }
  final projectionSettings = ProjectionSettingsService(
    settings: services.get<SettingsService>(),
    requested: preferences,
    backend: backend is ProjectionConfigurationBackend
        ? backend as ProjectionConfigurationBackend
        : null,
  );
  services.register(projectionSettings);
  lifecycle.registerShutdown(
    name: 'projection.settings',
    phase: AppShutdownPhase.stopActivity,
    shutdown: projectionSettings.close,
  );
  final media = CachedMediaSessionService();
  services.register<MediaSessionService>(media);
  lifecycle.registerShutdown(name: 'media.sessions', shutdown: media.close);
  if (connectivity != null) {
    final callAudio = BluetoothCallAudio(
      connectivity,
      services.get<AudioService>(),
    );
    lifecycle.registerShutdown(
      name: 'bluetooth.callAudio',
      phase: AppShutdownPhase.stopActivity,
      shutdown: callAudio.close,
    );
    final bluetoothMedia = BluetoothMediaSource(
      connectivity,
      media,
      audio: services.get<AudioService>(),
    );
    lifecycle.registerShutdown(
      name: 'bluetooth.mediaSource',
      phase: AppShutdownPhase.stopActivity,
      shutdown: bluetoothMedia.close,
    );
  }

  final backendType = ProjectionBackendType.fromEnvironment(environment);
  ProjectionViewRegistry? viewRegistry;
  if (renderTest.enabled ||
      backendType == ProjectionBackendType.androidAuto ||
      carPlayEnabled) {
    try {
      viewRegistry = (viewRegistryLoader ?? IhsProjectionViewRegistry.load)(
        libraryPath: environment['ARGO_PROJECTION_VIEW_LIBRARY'],
      );
      lifecycle.registerShutdown(
        name: 'projection.viewRegistry',
        phase: AppShutdownPhase.stopActivity,
        shutdown: viewRegistry.close,
      );
    } on Object catch (error, stackTrace) {
      if (renderTest.enabled) rethrow;
      diagnostics.error(
        'projection.view',
        'Native projection view is unavailable.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
  final ProjectionBackend presentationBackend;
  if (carPlayEnabled) {
    final carPlaySettings = CarPlaySettingsService(
      socketPath:
          '${environment['XDG_RUNTIME_DIR']}/project-argo/carplay-settings.sock',
      selectedMicrophone: () =>
          connectivity?.connectivity.voice?['selected'] as String?,
    );
    services.register<CarPlaySettingsService>(carPlaySettings);
    lifecycle.registerShutdown(
      name: 'carplay.settings',
      phase: AppShutdownPhase.stopActivity,
      shutdown: carPlaySettings.close,
    );
    await carPlaySettings.start();
    final carPlay = CarPlayProjectionBackend(
      selectedMicrophone: () =>
          connectivity?.connectivity.voice?['selected'] as String?,
      microphoneMuted: () => connectivity?.connectivity.voice?['muted'] == true,
      socketPath: projectionEndpoint(
        environment,
        'ARGO_CARPLAY_SOCKET',
        'carplay-control.sock',
      ),
    );
    presentationBackend = backend.protocol == null
        ? carPlay
        : MultiplexProjectionBackend([backend, carPlay]);
  } else {
    presentationBackend = backend;
  }
  final projection = await DefaultProjectionService.start(
    backend: presentationBackend,
    audio: services.get<AudioService>(),
    diagnostics: diagnostics,
  );
  final mediaSource = ProjectionMediaSource(
    projection,
    media,
    connectivity: services.contains<ConnectivityService>()
        ? services.get<ConnectivityService>()
        : null,
  );
  lifecycle.registerShutdown(
    name: 'projection.mediaSource',
    phase: AppShutdownPhase.stopActivity,
    shutdown: mediaSource.close,
  );
  lifecycle.registerShutdown(
    name: 'projection.service',
    phase: AppShutdownPhase.stopActivity,
    shutdown: projection.close,
  );
  services
    ..register<ProjectionPresentationOptions>(
      ProjectionPresentationOptions(
        geometryDiagnostics:
            environment['ARGO_PROJECTION_GEOMETRY_DIAGNOSTICS'] == '1',
      ),
    )
    ..register<ProjectionRenderTest>(renderTest)
    ..register<ProjectionBackend>(presentationBackend)
    ..register<ProjectionService>(projection);
  if (viewRegistry != null) {
    services.register<ProjectionViewRegistry>(viewRegistry);
  }
  diagnostics.info(
    'projection.backend',
    projection.current.backendAvailable
        ? 'Projection backend ready.'
        : 'Projection backend disabled or unavailable.',
  );
  return projection;
}
