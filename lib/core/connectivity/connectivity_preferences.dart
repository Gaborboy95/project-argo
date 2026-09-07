import 'dart:async';

import 'connectivity_service.dart';
import '../settings/app_setting_keys.dart';
import '../settings/settings_service.dart';

/// Stores only requested device/radio references. Never initiates a connection.
final class ConnectivityPreferences implements ConnectivityService {
  ConnectivityPreferences(this.backend, this.settings) {
    _subscription = backend.connectivityChanges.listen(_restore);
    _restore(backend.connectivity);
  }
  final ConnectivityService backend;
  final SettingsService settings;
  StreamSubscription<ConnectivitySnapshot>? _subscription;
  bool _restored = false;
  void _restore(ConnectivitySnapshot state) {
    if (_restored ||
        !state.available ||
        state.adapters.isEmpty ||
        state.networks.isEmpty) {
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
    if (state.adapters.any((r) => r.id == adapter)) {
      await backend.connectivityCommand('adapter', target: adapter);
    }
    if (state.networks.any((r) => r.id == interface)) {
      await backend.connectivityCommand('interface', target: interface);
    }
    if (state.devices.any((d) => d.id == phone && d.paired)) {
      await backend.connectivityCommand('select', target: phone);
    }
    // Each daemon/application launch starts disabled. Explicit enable is a
    // session-local authorization, deliberately not an autostart preference.
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
      _ => null,
    };
    if (key != null) await settings.set(key, target);
    if (action == 'forget' &&
        settings.get(AppSettingKeys.connectivityPhone) == target) {
      await settings.reset(AppSettingKeys.connectivityPhone);
    }
  }

  Future<void> close() async {
    await _subscription?.cancel();
  }
}
