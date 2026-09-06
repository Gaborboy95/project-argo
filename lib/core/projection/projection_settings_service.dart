import 'dart:async';

import '../diagnostics/diagnostics_service.dart';
import '../settings/app_setting_keys.dart';
import '../settings/settings_service.dart';
import 'projection_configuration.dart';
import 'projection_preferences.dart';

/// Persisted requests belong to Argo; only daemon acknowledgements are pending/active.
final class ProjectionSettingsService {
  ProjectionSettingsService({
    required this.settings,
    required this.requested,
    this.backend,
    this.notice,
  }) {
    _subscription = backend?.configurationChanges.listen((_) => _notify());
  }
  final SettingsService settings;
  final ProjectionConfigurationBackend? backend;
  ProjectionPreferences requested;
  String? notice;
  bool saving = false;
  bool _closed = false;
  StreamSubscription<ProjectionConfigurationState>? _subscription;
  final _changes = StreamController<void>.broadcast(sync: true);
  Stream<void> get changes => _changes.stream;
  ProjectionConfigurationState get current =>
      backend?.configuration ?? const ProjectionConfigurationState();

  static Future<ProjectionPreferences> load(
    SettingsService settings,
    DiagnosticsService diagnostics,
  ) async {
    try {
      return ProjectionPreferences.fromSettings(settings);
    } on ArgumentError catch (error, stack) {
      diagnostics.warning(
        'projection.settings',
        'Stored projection pair is unsupported; using 1280×720 defaults.',
        error: error,
        stackTrace: stack,
      );
      final fallback = ProjectionPreferences.defaults();
      await persist(settings, fallback);
      return fallback;
    }
  }

  static Future<void> persist(
    SettingsService settings,
    ProjectionPreferences p,
  ) async {
    await settings.set(AppSettingKeys.projectionDisplayWidth, p.width);
    await settings.set(AppSettingKeys.projectionDisplayHeight, p.height);
    await settings.set(AppSettingKeys.projectionDisplayDpi, p.dpi);
    await settings.set(
      AppSettingKeys.projectionFramesPerSecond,
      p.framesPerSecond,
    );
    await settings.set(AppSettingKeys.projectionDriverSide, p.driverSide.name);
  }

  Future<void> update(ProjectionPreferences value) async {
    if (_closed || saving) return;
    final caps = current.capabilities;
    if (caps == null || !caps.supports(value)) {
      notice =
          'Not saved: this request is not supported by the connected daemon.';
      _notify();
      return;
    }
    saving = true;
    notice = null;
    _notify();
    try {
      await persist(settings, value);
      requested = value;
      await backend!.requestConfiguration(value);
    } on Object catch (error) {
      notice = 'Projection preference update failed: $error';
    } finally {
      saving = false;
      _notify();
    }
  }

  void _notify() {
    if (!_closed) _changes.add(null);
  }

  Future<void> close() async {
    _closed = true;
    await _subscription?.cancel();
    await _changes.close();
  }
}
