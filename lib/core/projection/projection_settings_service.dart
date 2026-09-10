import 'dart:async';

import '../diagnostics/diagnostics_service.dart';
import '../settings/app_setting_keys.dart';
import '../settings/settings_service.dart';
import 'projection_configuration.dart';
import 'projection_preferences.dart';
import 'projection_types.dart';

/// Persisted requests belong to Argo; only daemon acknowledgements are pending/active.
final class ProjectionSettingsService {
  ProjectionSettingsService({
    required this.settings,
    required this.requested,
    this.backend,
    this.notice,
  }) {
    _subscription = backend?.configurationChanges.listen((_) {
      _notify();
      _scheduleViewport();
    });
  }
  final SettingsService settings;
  final ProjectionConfigurationBackend? backend;
  ProjectionPreferences requested;
  String? notice;
  bool saving = false;
  bool _closed = false;
  Future<void>? _operation;
  StreamSubscription<ProjectionConfigurationState>? _subscription;
  final _changes = StreamController<void>.broadcast(sync: true);
  Stream<void> get changes => _changes.stream;
  ProjectionConfigurationState get current =>
      backend?.configuration ?? const ProjectionConfigurationState();

  (double, double, double)? _viewport;
  (double, double, double)? get measuredViewport => _viewport;
  Future<void> calculateAutomatically() => update(
    requested.copyWith(
      viewInsets: const ProjectionInsets(),
      safeInsets: const ProjectionInsets(),
    ),
  );
  ProjectionPreferences? _sentViewport;
  Timer? _viewportTimer;
  ProjectionPreferences get effective {
    final v = _viewport;
    return v == null ? requested : requested.forViewport(v.$1, v.$2, v.$3);
  }

  void setViewport(double width, double height, double mediaHeight) {
    final next = (width, height, mediaHeight);
    if (_closed || _viewport == next) return;
    _viewport = next;
    _notify();
    _scheduleViewport();
  }

  void _scheduleViewport() {
    if (_closed || _viewport == null || backend == null) return;
    if (current.capabilities == null) {
      _sentViewport = null;
      return;
    }
    _viewportTimer?.cancel();
    _viewportTimer = Timer(const Duration(milliseconds: 150), () async {
      if (_closed || saving) return;
      try {
        final value = effective;
        if (value == _sentViewport ||
            current.capabilities?.supports(value) != true) {
          return;
        }
        _sentViewport = value;
        await backend!.requestConfiguration(value);
      } on Object catch (error) {
        _sentViewport = null;
        notice = 'View Area update failed: $error';
        _notify();
      }
    });
  }

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
    final keys = [
      AppSettingKeys.projectionViewInsetLeft,
      AppSettingKeys.projectionViewInsetTop,
      AppSettingKeys.projectionViewInsetRight,
      AppSettingKeys.projectionViewInsetBottom,
      AppSettingKeys.projectionSafeInsetLeft,
      AppSettingKeys.projectionSafeInsetTop,
      AppSettingKeys.projectionSafeInsetRight,
      AppSettingKeys.projectionSafeInsetBottom,
    ];
    final values = [
      p.viewInsets.left,
      p.viewInsets.top,
      p.viewInsets.right,
      p.viewInsets.bottom,
      p.safeInsets.left,
      p.safeInsets.top,
      p.safeInsets.right,
      p.safeInsets.bottom,
    ];
    for (var i = 0; i < keys.length; i++) {
      await settings.set(keys[i], values[i].toInt());
    }
  }

  Future<void> reset() {
    if (_closed || saving) return _operation ?? Future<void>.value();
    return _operation = _reset();
  }

  Future<void> _reset() async {
    if (_closed || saving) return;
    final defaults =
        current.capabilities?.defaults ?? ProjectionPreferences.defaults();
    if (current.capabilities != null) {
      await update(defaults);
      return;
    }
    saving = true;
    _notify();
    try {
      await persist(settings, defaults);
      requested = defaults;
      notice =
          'Defaults saved locally; not validated against a connected daemon.';
    } on Object catch (error) {
      notice = 'Could not save projection defaults: $error';
    } finally {
      saving = false;
      _notify();
    }
  }

  Future<void> update(ProjectionPreferences value) {
    if (_closed || saving) return _operation ?? Future<void>.value();
    return _operation = _update(value);
  }

  Future<void> _update(ProjectionPreferences value) async {
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
      await backend!.requestConfiguration(effective);
      _sentViewport = effective;
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
    _viewportTimer?.cancel();
    await _subscription?.cancel();
    if (saving) await _operation;
    await _changes.close();
  }
}
