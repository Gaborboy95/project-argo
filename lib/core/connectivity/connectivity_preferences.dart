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
  }) : _startupPending = {...startupConnections} {
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
  final Set<String> _startupPending;
  Timer? _startupDeadline;
  String? _startupPhone;
  bool _choicesRestored = false;
  bool _restored = false;

  void _startup(ConnectivitySnapshot state) {
    if (!_choicesRestored ||
        !state.daemonConnected ||
        !state.available ||
        state.selected != _startupPhone ||
        state.cleanupError.isNotEmpty ||
        !state.devices.any((d) => d.id == state.selected && d.paired)) {
      return;
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
      await backend.connectivityCommand(
        'band',
        target: settings.get(AppSettingKeys.connectivityBand),
      );
    }
    final adapter = settings.get(AppSettingKeys.connectivityAdapter);
    final interface = settings.get(AppSettingKeys.connectivityInterface);
    final phone = settings.get(AppSettingKeys.connectivityPhone);
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
      await backend.connectivityCommand('interface', target: interface);
    }
    final phoneAddress = phone.contains('/') ? phone.split('/').last : '';
    final restoredPhone = radio != null && phoneAddress.isNotEmpty
        ? '${radio.id}/$phoneAddress'
        : phone;
    if ((adapter.isEmpty || radio != null) &&
        state.devices.any((d) => d.id == restoredPhone && d.paired)) {
      _startupPhone = restoredPhone;
      await backend.connectivityCommand('select', target: restoredPhone);
    }
    _choicesRestored = true;
    _startup(backend.connectivity);
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
      _startupPending.clear();
    } else if (action == 'disconnect' ||
        ({'enable', 'projectionEnabled'}.contains(action) && !accept)) {
      _startupPending.remove('wireless');
    } else if (action == 'musicDisconnect' || action == 'musicConnect') {
      _startupPending.remove('music');
    } else if (action == 'callsDisconnect' || action == 'callsConnect') {
      _startupPending.remove('calls');
    } else if (action == 'connect') {
      _startupPending.remove('wireless');
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
        settings.get(AppSettingKeys.connectivityPhone) == target) {
      await settings.reset(AppSettingKeys.connectivityPhone);
    }
  }

  Future<void> close() async {
    _startupDeadline?.cancel();
    _startupPending.clear();
    await _subscription?.cancel();
  }
}
