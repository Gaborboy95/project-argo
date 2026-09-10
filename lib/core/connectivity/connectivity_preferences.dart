import 'dart:async';

import 'connectivity_service.dart';
import '../settings/app_setting_keys.dart';
import '../settings/settings_service.dart';

/// Restores opaque device choices; optional startup requests use existing controllers.
final class ConnectivityPreferences implements ConnectivityService {
  ConnectivityPreferences(
    this.backend,
    this.settings, {
    Set<String> startupConnections = const {},
    Timer Function(Duration, void Function()) deadlineTimer = Timer.new,
  }) : _startupPending = settings.get(AppSettingKeys.autoConnectPhone)
           ? {'phone', ...startupConnections}
           : {} {
    _settingsSubscription = settings.changes.listen((change) {
      if (change.keyId == AppSettingKeys.autoConnectPhone.id &&
          !settings.get(AppSettingKeys.autoConnectPhone)) {
        _startupPending.clear();
        _startupDeadline?.cancel();
      }
    });
    if (_startupPending.isNotEmpty) {
      _startupDeadline = deadlineTimer(const Duration(seconds: 30), () {
        _startupPending.clear();
      });
    }
    _subscription = backend.connectivityChanges.listen(_restore);
    _restore(backend.connectivity);
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
  bool _restored = false;

  void _startup(ConnectivitySnapshot state) {
    if (!settings.get(AppSettingKeys.autoConnectPhone)) {
      _startupPending.clear();
      return;
    }
    if (!_choicesRestored ||
        !state.daemonConnected ||
        !state.available ||
        state.selected != _startupPhone ||
        state.cleanupError.isNotEmpty ||
        !state.devices.any((d) => d.id == state.selected && d.paired)) {
      return;
    }
    if (_startupPending.contains('phone')) {
      if (state.enabled && state.wirelessAvailable == true) {
        _startupPending.remove('phone');
        _startupPending.add('wireless');
      } else if ((!state.enabled || state.wirelessAvailable == false) &&
          state.music != null) {
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
      if (!ready) continue;
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
      unawaited(
        backend
            .connectivityCommand(action, target: state.selected)
            .catchError((Object _) {}),
      );
    }
  }

  bool _microphoneRestored = false;
  void _restore(ConnectivitySnapshot state) {
    if (_choicesRestored) _restorePhone(state);
    _startup(state);
    final input = settings.get(AppSettingKeys.microphoneInput);
    if (!_microphoneRestored && input.isNotEmpty && state.voice != null) {
      _microphoneRestored = true;
      unawaited(
        backend
            .connectivityCommand('microphone', target: input)
            .catchError((Object _) {}),
      );
    }
    if (_restored || !state.available || state.adapters.isEmpty) {
      return;
    }
    _restored = true;
    unawaited(_restoreChoices(state).catchError((Object _) {}));
  }

  Future<void> _restoreChoices(ConnectivitySnapshot state) async {
    if (state.band != null) {
      await backend
          .connectivityCommand(
            'band',
            target: settings.get(AppSettingKeys.connectivityBand),
          )
          .catchError((Object _) {});
    }
    final adapter = settings.get(AppSettingKeys.connectivityAdapter);
    final interface = settings.get(AppSettingKeys.connectivityInterface);
    if (_selectionSuppressed) return;
    final radio = state.adapters
        .where((r) => r.address == adapter || r.id == adapter)
        .firstOrNull;
    if (adapter.isNotEmpty) {
      await backend.connectivityCommand(
        'adapter',
        target: radio?.address ?? adapter,
      );
      // Migrate older hciN preferences without changing BlueZ bonds.
      if (radio != null) {
        await settings.set(
          AppSettingKeys.connectivityAdapter,
          radio.address ?? radio.id,
        );
      }
    }
    if (state.networks.any((r) => r.id == interface)) {
      await backend
          .connectivityCommand('interface', target: interface)
          .catchError((Object _) {});
    }
    _choicesRestored = true;
    _restorePhone(backend.connectivity);
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
    _startupPhone = restoredPhone;
    unawaited(() async {
      try {
        if (!_selectionSuppressed && state.selected != restoredPhone) {
          await backend.connectivityCommand('select', target: restoredPhone);
        }
        if (!_selectionSuppressed) _startup(backend.connectivity);
      } on Object {
        /* Missing/forgotten phone remains ordinary disconnected UI. */
      } finally {
        _selectingPhone = false;
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
    if ({'forget', 'stopAll', 'adapter', 'select'}.contains(action)) {
      _selectionSuppressed = true;
      _startupPending.clear();
    } else if ({
          'disconnect',
          'musicDisconnect',
          'callsDisconnect',
        }.contains(action) ||
        ({'enable', 'projectionEnabled'}.contains(action) && !accept)) {
      _startupPending.clear();
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
    _startupDeadline?.cancel();
    _startupPending.clear();
    await _settingsSubscription?.cancel();
    await _subscription?.cancel();
  }
}
