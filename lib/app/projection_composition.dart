import '../core/audio/audio_service.dart';
import '../core/diagnostics/diagnostics_service.dart';
import '../core/lifecycle/app_lifecycle_coordinator.dart';
import '../core/projection/projection_backend.dart';
import '../core/projection/projection_backend_type.dart';
import '../core/projection/projection_preferences.dart';
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
  AndroidAutoIdentityValidator? identityValidator,
  ProjectionViewRegistry Function({String? libraryPath})? viewRegistryLoader,
}) async {
  final preferences = ProjectionPreferences.fromSettings(
    services.get<SettingsService>(),
  );
  final backend = await selectProjectionBackend(
    environment: environment,
    preferences: preferences,
    diagnostics: diagnostics,
    isLinux: isLinux,
    transportFactory: transportFactory,
    identityValidator: identityValidator,
  );
  final backendType = ProjectionBackendType.fromEnvironment(environment);
  ProjectionViewRegistry? viewRegistry;
  if (backendType == ProjectionBackendType.androidAuto) {
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
      diagnostics.error(
        'projection.view',
        'Native projection view is unavailable.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
  final projection = await DefaultProjectionService.start(
    backend: backend,
    audio: services.get<AudioService>(),
    diagnostics: diagnostics,
  );
  lifecycle.registerShutdown(
    name: 'projection.service',
    phase: AppShutdownPhase.stopActivity,
    shutdown: projection.close,
  );
  services
    ..register<ProjectionBackend>(backend)
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
