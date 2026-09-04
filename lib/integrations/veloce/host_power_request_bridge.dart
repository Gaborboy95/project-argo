import 'dart:async';
import 'dart:io';

import 'package:veloce_lua_core/veloce_lua_core.dart';

import '../../core/diagnostics/diagnostics_service.dart';
import '../../core/power/head_unit_operational_state.dart';
import '../../core/power/head_unit_power_service.dart';
import '../../core/power/head_unit_power_snapshot.dart';
import '../../core/power/host_power_controller.dart';
import '../../core/vehicle/vehicle_transport_lifecycle.dart';
import 'vehicle_integration_plugin_authorizer.dart';

typedef SettingsFlush = Future<void> Function();

/// Admits narrow privileged power requests from the active vehicle integration.
final class HostPowerRequestBridge {
  HostPowerRequestBridge._({
    required this.authorizer,
    required this.powerService,
    required this.hostPowerController,
    required this.transportLifecycle,
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

  static const suspendRequestTopic = 'host.power.suspend.request';
  static const shutdownRequestTopic = 'host.power.shutdown.request';
  static const _ownerId = 'argo.host-power-request-bridge';
  static const _diagnosticSource = 'host.power';
  static const _transportDiagnosticSource = 'vehicle.transport';

  static Future<HostPowerRequestBridge> start({
    required PluginEventBus eventBus,
    required PluginRegistry pluginRegistry,
    required VelocePluginLoadedLookup isPluginLoaded,
    required Directory? activeIntegrationPluginRoot,
    required HeadUnitPowerService powerService,
    required HostPowerController hostPowerController,
    required VehicleTransportLifecycle transportLifecycle,
    required SettingsFlush flushSettings,
    required DiagnosticsService diagnostics,
  }) async {
    final authorizer = await VehicleIntegrationPluginAuthorizer.create(
      pluginRegistry: pluginRegistry,
      isPluginLoaded: isPluginLoaded,
      activeIntegrationPluginRoot: activeIntegrationPluginRoot,
      diagnostics: diagnostics,
    );
    final bridge = HostPowerRequestBridge._(
      authorizer: authorizer,
      powerService: powerService,
      hostPowerController: hostPowerController,
      transportLifecycle: transportLifecycle,
      flushSettings: flushSettings,
      diagnostics: diagnostics,
    );
    try {
      bridge._start(eventBus);
      return bridge;
    } on Object catch (error, stackTrace) {
      try {
        await bridge.close();
      } on Object {
        // Preserve the subscription startup failure.
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  final VehicleIntegrationPluginAuthorizer authorizer;
  final HeadUnitPowerService powerService;
  final HostPowerController hostPowerController;
  final VehicleTransportLifecycle transportLifecycle;
  final SettingsFlush flushSettings;
  final DiagnosticsService diagnostics;

  final List<PluginEventSubscription> _eventSubscriptions = [];
  StreamSubscription<HeadUnitPowerSnapshot>? _powerSubscription;
  Future<void>? _closeFuture;
  var _closed = false;
  var _requestInProgress = false;
  bool _isInStandby;
  int _standbyEpisode;
  var _handledThisStandbyEpisode = false;

  void _start(PluginEventBus eventBus) {
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
    _eventSubscriptions.add(
      eventBus.subscribe(
        ownerId: _ownerId,
        topic: suspendRequestTopic,
        handler: _onSuspendRequested,
      ),
    );
    _eventSubscriptions.add(
      eventBus.subscribe(
        ownerId: _ownerId,
        topic: shutdownRequestTopic,
        handler: _onShutdownRequested,
      ),
    );
  }

  Future<void> _onSuspendRequested(PluginEvent event) => _runExclusive(
    operation: 'suspend',
    action: () => _handleSuspendRequest(event),
  );

  Future<void> _onShutdownRequested(PluginEvent event) => _runExclusive(
    operation: 'shutdown',
    action: () => _handleShutdownRequest(event),
  );

  Future<void> _runExclusive({
    required String operation,
    required Future<void> Function() action,
  }) async {
    if (_closed) return;
    if (_requestInProgress) {
      diagnostics.info(
        _diagnosticSource,
        'Host $operation request suppressed: another host power operation is '
        'in progress.',
      );
      return;
    }
    _requestInProgress = true;
    try {
      await action();
    } finally {
      _requestInProgress = false;
    }
  }

  Future<void> _handleSuspendRequest(PluginEvent event) async {
    final pluginId = await _authorizedPluginId(event, 'suspend');
    if (pluginId == null) return;
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

    await _flushSettingsBefore('suspend');
    if (_closed) return;
    if (!_sameStandbyEpisode(standbyEpisode)) {
      _rejectStaleSuspend();
      return;
    }
    if (!await _quiesceTransport()) return;
    if (_closed || !_sameStandbyEpisode(standbyEpisode)) {
      if (!_closed) _rejectStaleSuspend();
      await _resumeTransport();
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
    } finally {
      await _resumeTransport();
    }
  }

  Future<void> _handleShutdownRequest(PluginEvent event) async {
    final pluginId = await _authorizedPluginId(event, 'shutdown');
    if (pluginId == null) return;
    diagnostics.info(
      _diagnosticSource,
      'Host shutdown requested by plugin $pluginId.',
    );
    if (!hostPowerController.isEnabled) {
      diagnostics.info(
        _diagnosticSource,
        'Host power control disabled; shutdown suppressed.',
      );
      return;
    }

    await _flushSettingsBefore('shutdown');
    if (_closed || !await _quiesceTransport()) return;
    if (_closed) {
      await _resumeTransport();
      return;
    }

    diagnostics.info(_diagnosticSource, 'Host shutdown requested.');
    try {
      await hostPowerController.powerOff();
      diagnostics.info(_diagnosticSource, 'Host shutdown completed.');
    } on Object catch (error, stackTrace) {
      diagnostics.error(
        _diagnosticSource,
        'Host shutdown failed.',
        error: error,
        stackTrace: stackTrace,
      );
      await _resumeTransport();
    }
  }

  Future<String?> _authorizedPluginId(
    PluginEvent event,
    String operation,
  ) async {
    final pluginId = event.sourcePluginId;
    if (pluginId == null) {
      diagnostics.warning(
        _diagnosticSource,
        'Host $operation request rejected: anonymous event.',
      );
      return null;
    }
    if (!await authorizer.allows(pluginId)) {
      diagnostics.warning(
        _diagnosticSource,
        'Host $operation request rejected: unauthorized plugin $pluginId.',
      );
      return null;
    }
    return pluginId;
  }

  Future<void> _flushSettingsBefore(String operation) async {
    try {
      await flushSettings();
    } on Object catch (error, stackTrace) {
      diagnostics.warning(
        _diagnosticSource,
        'Settings flush failed before $operation.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<bool> _quiesceTransport() async {
    diagnostics.info(_transportDiagnosticSource, 'CAN transport quiescing.');
    try {
      await transportLifecycle.quiesce();
      diagnostics.info(_transportDiagnosticSource, 'CAN transport quiesced.');
      return true;
    } on Object catch (error, stackTrace) {
      diagnostics.error(
        _transportDiagnosticSource,
        'CAN transport quiesce failed.',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  Future<bool> _resumeTransport() async {
    diagnostics.info(_transportDiagnosticSource, 'CAN transport resuming.');
    try {
      await transportLifecycle.resume();
      diagnostics.info(_transportDiagnosticSource, 'CAN transport resumed.');
      return true;
    } on Object catch (error, stackTrace) {
      diagnostics.error(
        _transportDiagnosticSource,
        'CAN transport resume failed.',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  bool get _currentlyStandby =>
      _isInStandby &&
      powerService.current.operationalState == HeadUnitOperationalState.standby;

  bool _sameStandbyEpisode(int episode) =>
      _currentlyStandby && episode == _standbyEpisode;

  void _rejectStaleSuspend() {
    diagnostics.warning(
      _diagnosticSource,
      'Host suspend request rejected: vehicle no longer standby.',
    );
  }

  void _onPowerChanged(HeadUnitPowerSnapshot snapshot) {
    final isInStandby =
        snapshot.operationalState == HeadUnitOperationalState.standby;
    if (isInStandby == _isInStandby) return;
    _isInStandby = isInStandby;
    if (isInStandby) _standbyEpisode++;
    _handledThisStandbyEpisode = false;
  }

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

    for (final subscription in _eventSubscriptions) {
      await cancel(subscription.cancel);
    }
    _eventSubscriptions.clear();
    if (_powerSubscription case final subscription?) {
      await cancel(subscription.cancel);
    }
    if (firstError case final error?) {
      Error.throwWithStackTrace(error, firstStackTrace!);
    }
  }
}
