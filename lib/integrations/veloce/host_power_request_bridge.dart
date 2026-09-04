import 'dart:async';
import 'dart:io';

import 'package:veloce_lua_core/veloce_lua_core.dart';

import '../../core/diagnostics/diagnostics_service.dart';
import '../../core/power/head_unit_operational_state.dart';
import '../../core/power/head_unit_power_service.dart';
import '../../core/power/head_unit_power_snapshot.dart';
import '../../core/power/host_power_controller.dart';

typedef VelocePluginLoadedLookup = bool Function(String pluginId);
typedef SettingsFlush = Future<void> Function();

/// Admits one narrowly defined privileged request from the active vehicle
/// integration after checking both plugin provenance and current vehicle state.
final class HostPowerRequestBridge {
  HostPowerRequestBridge._({
    required this.pluginRegistry,
    required this.isPluginLoaded,
    required this.activeIntegrationPluginRoot,
    required this.powerService,
    required this.hostPowerController,
    required this.flushSettings,
    required this.diagnostics,
  }) : _isInStandby =
           powerService.current.operationalState ==
           HeadUnitOperationalState.standby,
       _standbyEpisode =
           powerService.current.operationalState ==
               HeadUnitOperationalState.standby
           ? 1
           : 0;

  Future<void> _start(PluginEventBus eventBus) async {
    _powerSubscription = powerService.changes.listen(
      _onPowerChanged,
      onError: (Object error, StackTrace stackTrace) {
        diagnostics.warning(
          _diagnosticSource,
          'Could not track the current standby episode.',
          error: error,
          stackTrace: stackTrace,
        );
      },
    );
    _eventSubscription = eventBus.subscribe(
      ownerId: _ownerId,
      topic: suspendRequestTopic,
      handler: _onSuspendRequested,
    );
  }

  static const suspendRequestTopic = 'host.power.suspend.request';
  static const _ownerId = 'argo.host-power-request-bridge';
  static const _diagnosticSource = 'host.power';

  static Future<HostPowerRequestBridge> start({
    required PluginEventBus eventBus,
    required PluginRegistry pluginRegistry,
    required VelocePluginLoadedLookup isPluginLoaded,
    required Directory? activeIntegrationPluginRoot,
    required HeadUnitPowerService powerService,
    required HostPowerController hostPowerController,
    required SettingsFlush flushSettings,
    required DiagnosticsService diagnostics,
  }) async {
    final canonicalRoot = activeIntegrationPluginRoot == null
        ? null
        : Directory(await activeIntegrationPluginRoot.resolveSymbolicLinks());
    final bridge = HostPowerRequestBridge._(
      pluginRegistry: pluginRegistry,
      isPluginLoaded: isPluginLoaded,
      activeIntegrationPluginRoot: canonicalRoot,
      powerService: powerService,
      hostPowerController: hostPowerController,
      flushSettings: flushSettings,
      diagnostics: diagnostics,
    );
    try {
      await bridge._start(eventBus);
      return bridge;
    } on Object catch (error, stackTrace) {
      await bridge.close();
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  final PluginRegistry pluginRegistry;
  final VelocePluginLoadedLookup isPluginLoaded;
  final Directory? activeIntegrationPluginRoot;
  final HeadUnitPowerService powerService;
  final HostPowerController hostPowerController;
  final SettingsFlush flushSettings;
  final DiagnosticsService diagnostics;

  PluginEventSubscription? _eventSubscription;
  StreamSubscription<HeadUnitPowerSnapshot>? _powerSubscription;
  Future<void>? _activeRequest;
  Future<void>? _closeFuture;
  var _closed = false;
  bool _isInStandby;
  int _standbyEpisode;
  var _handledThisStandbyEpisode = false;

  Future<void> _onSuspendRequested(PluginEvent event) async {
    if (_closed) return;
    final pluginId = event.sourcePluginId;
    if (pluginId == null) {
      diagnostics.warning(
        _diagnosticSource,
        'Host suspend request rejected: anonymous event.',
      );
      return;
    }
    if (!await _isAuthorized(pluginId)) {
      diagnostics.warning(
        _diagnosticSource,
        'Host suspend request rejected: unauthorized plugin $pluginId.',
      );
      return;
    }
    if (!_currentlyStandby) {
      diagnostics.warning(
        _diagnosticSource,
        'Host suspend request rejected: vehicle no longer standby.',
      );
      return;
    }
    if (_handledThisStandbyEpisode) {
      diagnostics.info(
        _diagnosticSource,
        'Host suspend request suppressed: already handled this standby '
        'episode.',
      );
      return;
    }
    if (_activeRequest != null) {
      diagnostics.info(
        _diagnosticSource,
        'Host suspend request suppressed: suspend is already in progress.',
      );
      return;
    }

    final standbyEpisode = _standbyEpisode;
    _handledThisStandbyEpisode = true;
    diagnostics.info(
      _diagnosticSource,
      'Host suspend requested by plugin $pluginId.',
    );

    if (!hostPowerController.isEnabled) {
      diagnostics.info(
        _diagnosticSource,
        'Host power control disabled; suspend suppressed.',
      );
      return;
    }

    final request = _performSuspend(standbyEpisode);
    _activeRequest = request;
    try {
      await request;
    } finally {
      if (identical(_activeRequest, request)) _activeRequest = null;
    }
  }

  Future<void> _performSuspend(int standbyEpisode) async {
    try {
      await flushSettings();
    } on Object catch (error, stackTrace) {
      diagnostics.warning(
        _diagnosticSource,
        'Settings flush failed before suspend.',
        error: error,
        stackTrace: stackTrace,
      );
    }

    if (_closed) return;
    if (!_currentlyStandby || standbyEpisode != _standbyEpisode) {
      diagnostics.warning(
        _diagnosticSource,
        'Host suspend request rejected: vehicle no longer standby.',
      );
      return;
    }

    diagnostics.info(_diagnosticSource, 'Host suspend requested.');
    try {
      await hostPowerController.suspend();
      diagnostics.info(_diagnosticSource, 'Host suspend completed.');
    } on Object catch (error, stackTrace) {
      diagnostics.error(
        _diagnosticSource,
        'Host suspend failed.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  bool get _currentlyStandby =>
      _isInStandby &&
      powerService.current.operationalState == HeadUnitOperationalState.standby;

  void _onPowerChanged(HeadUnitPowerSnapshot snapshot) {
    final isInStandby =
        snapshot.operationalState == HeadUnitOperationalState.standby;
    if (isInStandby == _isInStandby) return;
    _isInStandby = isInStandby;
    if (isInStandby) _standbyEpisode++;
    _handledThisStandbyEpisode = false;
  }

  Future<bool> _isAuthorized(String pluginId) async {
    final root = activeIntegrationPluginRoot;
    if (root == null || !isPluginLoaded(pluginId)) return false;
    final record = pluginRegistry[pluginId];
    if (record == null || record.state != PluginState.running) return false;

    try {
      final pluginDirectory = Directory(
        await Directory(record.directoryPath).resolveSymbolicLinks(),
      );
      final current = pluginRegistry[pluginId];
      if (!identical(record, current) ||
          !isPluginLoaded(pluginId) ||
          current?.state != PluginState.running) {
        return false;
      }
      return _isContained(root.path, pluginDirectory.path);
    } on FileSystemException catch (error, stackTrace) {
      diagnostics.warning(
        _diagnosticSource,
        'Could not validate host suspend request provenance for $pluginId.',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  static bool _isContained(String rootPath, String childPath) {
    final normalizedRoot = _normalizePath(rootPath);
    final rootWithSeparator = normalizedRoot.endsWith(Platform.pathSeparator)
        ? normalizedRoot
        : '$normalizedRoot${Platform.pathSeparator}';
    return _normalizePath(childPath).startsWith(rootWithSeparator);
  }

  static String _normalizePath(String path) =>
      Platform.isWindows ? path.toLowerCase() : path;

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closed = true;
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> cancel(Future<void> Function() operation) async {
      try {
        await operation();
      } on Object catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    if (_eventSubscription case final subscription?) {
      await cancel(subscription.cancel);
    }
    if (_powerSubscription case final subscription?) {
      await cancel(subscription.cancel);
    }
    final activeRequest = _activeRequest;
    if (activeRequest != null) {
      await cancel(() => activeRequest);
    }
    if (firstError case final error?) {
      Error.throwWithStackTrace(error, firstStackTrace!);
    }
  }
}
