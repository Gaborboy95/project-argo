import 'dart:async';

import 'package:flutter/foundation.dart';

import 'connectivity_service.dart';
import '../diagnostics/diagnostics_service.dart';
import '../settings/app_setting_keys.dart';
import '../settings/settings_service.dart';

/// Restores opaque device choices; optional startup requests use existing controllers.
final class ConnectivityPreferences implements ConnectivityService {
  ConnectivityPreferences(
    this.backend,
    this.settings, {
    Set<String> startupConnections = const {},
    this.projectionConfigured = true,
    this.diagnostics,
    this.deadlineTimer = Timer.new,
  }) : _startupPending = settings.get(AppSettingKeys.autoConnectPhone)
           ? {'phone', ...startupConnections}
           : {} {
    _settingsSubscription = settings.changes.listen((change) {
      if (change.keyId == AppSettingKeys.autoConnectPhone.id &&
          !settings.get(AppSettingKeys.autoConnectPhone)) {
        _cancelStartup();
        _selectionSuppressed = true;
      }
    });
    _subscription = backend.connectivityChanges.listen(_restore);
    _restore(backend.connectivity);
  }
  static const startupDiscoveryWindow = Duration(seconds: 90);
  final Timer Function(Duration, void Function()) deadlineTimer;
  final bool projectionConfigured;
  final DiagnosticsService? diagnostics;
  final Set<String> _reported = {};
  void _info(String message) {
    if (!_reported.add(message)) return;
    diagnostics?.info('connectivity.startup', message);
    // Fixed, bounded lifecycle messages also reach the managed app journal.
    debugPrint('Info [connectivity.startup] $message');
  }

  void _cancelStartup() {
    if (_startupPending.isNotEmpty) _info('Startup auto-connect cancelled');
    _startupPending.clear();
    _startupDeadline?.cancel();
  }

  final ConnectivityService backend;
  final SettingsService settings;
  StreamSubscription<ConnectivitySnapshot>? _subscription;
  StreamSubscription<SettingChange>? _settingsSubscription;
  bool _selectionSuppressed = false, _selectingPhone = false;
  final Set<String> _startupPending;
  Timer? _startupDeadline;
  String? _startupPhone;
  bool _choicesRestored = false;
  bool _restoringChoices = false;

  void _startup(ConnectivitySnapshot state) {
    if (_startupPending.isEmpty) return;
    if (!settings.get(AppSettingKeys.autoConnectPhone)) {
      _cancelStartup();
      return;
    }
    if (!_choicesRestored ||
        !state.daemonConnected ||
        !state.available ||
        state.adapters.isEmpty) {
      _info('Waiting for remembered adapter/phone');
      return;
    }
    _startupDeadline ??= deadlineTimer(startupDiscoveryWindow, () {
      _info('Startup auto-connect expired');
      _startupPending.clear();
      _selectionSuppressed = true;
    });
    _info('Startup auto-connect armed: 90-second discovery window');
    if (_selectingPhone ||
        _startupPhone == null ||
        state.selected != _startupPhone ||
        !state.devices.any((d) => d.id == _startupPhone && d.paired)) {
      _info('Waiting for remembered adapter/phone');
      return;
    }
    _info('Remembered phone restored');
    if (state.cleanupError.isNotEmpty) return;
    if (_startupPending.contains('phone')) {
      if (projectionConfigured) {
        _startupPending.remove('phone');
        _startupPending.add('wireless');
      } else if (state.music != null) {
        _startupPending.remove('phone');
        _startupPending.add('music');
      }
    }
    // Consume before sending. Radio loss, suspension and later snapshots cannot
    // rearm these requests. Provider controllers own their bounded retries.
    for (final source in _startupPending.toList()) {
      final ready = switch (source) {
        'wireless' => state.enabled && state.wirelessAvailable == true,
        'music' => state.music != null,
        'calls' => state.calls?['available'] == true,
        _ => false,
      };
      if (!ready) {
        if (source == 'wireless') _info('Waiting for wireless readiness');
        continue;
      }
      _startupPending.remove(source);
      final phase = switch (source) {
        'wireless' => state.phase,
        'music' => state.music?['phase'],
        _ => state.calls?['phase'],
      };
      if ({
        'preparing',
        'bootstrap',
        'connecting',
        'connected',
        'projecting',
        'streaming',
        'suspended',
        'backoff',
        'retrying',
        'waiting',
        'waiting-audio',
        'routing-failed',
        'disconnecting',
        'cleanup',
      }.contains(phase)) {
        continue;
      }
      final action = switch (source) {
        'wireless' => 'connect',
        'music' => 'musicConnect',
        _ => 'callsConnect',
      };
      _info(
        source == 'wireless'
            ? 'Wireless request issued'
            : '$source startup request issued',
      );
      unawaited(
        backend
            .connectivityCommand(action, target: state.selected)
            .catchError((Object _) {}),
      );
    }
    if (_startupPending.isEmpty) _startupDeadline?.cancel();
  }

  bool _microphoneRestored = false;
  void _restore(ConnectivitySnapshot state) {
    _startup(state);
    if (_choicesRestored) _restorePhone(state);
    final input = settings.get(AppSettingKeys.microphoneInput);
    if (!_microphoneRestored && input.isNotEmpty && state.voice != null) {
      _microphoneRestored = true;
      unawaited(
        backend
            .connectivityCommand('microphone', target: input)
            .catchError((Object _) {}),
      );
    }
    if (_choicesRestored ||
        _restoringChoices ||
        _selectionSuppressed ||
        !state.daemonConnected ||
        !state.available ||
        state.adapters.isEmpty) {
      return;
    }
    _restoringChoices = true;
    unawaited(
      _restoreChoices(state).catchError((Object _) {}).whenComplete(() {
        _restoringChoices = false;
        if (_choicesRestored && !_selectionSuppressed) {
          _restore(backend.connectivity);
        }
      }),
    );
  }

  Future<void> _restoreChoices(ConnectivitySnapshot state) async {
    final adapter = settings.get(AppSettingKeys.connectivityAdapter);
    final interface = settings.get(AppSettingKeys.connectivityInterface);
    final radio = state.adapters
        .where((r) => r.address == adapter || r.id == adapter)
        .firstOrNull;
    if (_selectionSuppressed ||
        (adapter.isNotEmpty && radio == null) ||
        (interface.isNotEmpty &&
            !state.networks.any((r) => r.id == interface))) {
      return;
    }
    if (state.band != null) {
      await backend.connectivityCommand(
        'band',
        target: settings.get(AppSettingKeys.connectivityBand),
      );
    }
    if (_selectionSuppressed) return;
    if (adapter.isNotEmpty) {
      await backend.connectivityCommand(
        'adapter',
        target: radio?.address ?? adapter,
      );
      // A user selection while the command was pending owns the saved choice.
      if (_selectionSuppressed) return;
      // Migrate older hciN preferences without changing BlueZ bonds.
      if (radio != null) {
        await settings.set(
          AppSettingKeys.connectivityAdapter,
          radio.address ?? radio.id,
        );
      }
    }
    if (_selectionSuppressed) return;
    if (state.networks.any((r) => r.id == interface)) {
      await backend.connectivityCommand('interface', target: interface);
    }
    if (!_selectionSuppressed) _choicesRestored = true;
  }

  void _restorePhone(ConnectivitySnapshot state) {
    if (_selectionSuppressed || _selectingPhone || _startupPhone != null) {
      return;
    }
    final phone = settings.get(AppSettingKeys.connectivityPhone);
    final adapter = settings.get(AppSettingKeys.connectivityAdapter);
    final radio = state.adapters
        .where((r) => r.address == adapter || r.id == adapter)
        .firstOrNull;
    final phoneAddress = phone.contains('/') ? phone.split('/').last : '';
    final restoredPhone = radio != null && phoneAddress.isNotEmpty
        ? '${radio.id}/$phoneAddress'
        : phone;
    if ((adapter.isNotEmpty && radio == null) ||
        !state.devices.any((d) => d.id == restoredPhone && d.paired)) {
      return;
    }
    _selectingPhone = true;
    unawaited(() async {
      try {
        if (!_selectionSuppressed && state.selected != restoredPhone) {
          await backend.connectivityCommand('select', target: restoredPhone);
        }
        if (!_selectionSuppressed) _startupPhone = restoredPhone;
      } on Object {
        /* Missing/forgotten phone remains ordinary disconnected UI. */
      } finally {
        _selectingPhone = false;
        if (!_selectionSuppressed) _startup(backend.connectivity);
      }
    }());
  }

  @override
  ConnectivitySnapshot get connectivity => backend.connectivity;
  @override
  Stream<ConnectivitySnapshot> get connectivityChanges =>
      backend.connectivityChanges;
  @override
  Future<void> connectivityCommand(
    String action, {
    String target = '',
    bool accept = false,
    int prompt = 0,
  }) async {
    // Explicit intent wins even while waiting for inventory/restore or a failed
    // command. Startup never chooses a different phone after Forget/selection.
    if ({
      'forget',
      'stopAll',
      'adapter',
      'interface',
      'select',
    }.contains(action)) {
      _selectionSuppressed = true;
      _cancelStartup();
    } else if ({
          'disconnect',
          'musicDisconnect',
          'callsDisconnect',
        }.contains(action) ||
        ({'enable', 'projectionEnabled'}.contains(action) && !accept)) {
      _selectionSuppressed = true;
      _cancelStartup();
    } else if ({'connect', 'musicConnect', 'callsConnect'}.contains(action)) {
      _startupPending.remove('phone');
      _startupPending.remove(
        action == 'connect'
            ? 'wireless'
            : action == 'musicConnect'
            ? 'music'
            : 'calls',
      );
    }
    if (_startupPending.isEmpty) _startupDeadline?.cancel();
    await backend.connectivityCommand(
      action,
      target: target,
      accept: accept,
      prompt: prompt,
    );
    final key = switch (action) {
      'adapter' => AppSettingKeys.connectivityAdapter,
      'interface' => AppSettingKeys.connectivityInterface,
      'select' => AppSettingKeys.connectivityPhone,
      'band' => AppSettingKeys.connectivityBand,
      'microphone' => AppSettingKeys.microphoneInput,
      _ => null,
    };
    if (key != null) {
      final radio = connectivity.adapters
          .where((r) => r.id == target || r.address == target)
          .firstOrNull;
      await settings.set(
        key,
        action == 'adapter' ? (radio?.address ?? target) : target,
      );
    }
    if (action == 'forget' &&
        (settings.get(AppSettingKeys.connectivityPhone) == target ||
            target == _startupPhone)) {
      await settings.reset(AppSettingKeys.connectivityPhone);
    }
  }

  Future<void> close() async {
    _selectionSuppressed = true;
    _cancelStartup();
    await _settingsSubscription?.cancel();
    await _subscription?.cancel();
  }
}
