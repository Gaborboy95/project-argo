import 'dart:async';

import 'package:argo/core/connectivity/connectivity_preferences.dart';
import 'package:argo/core/connectivity/connectivity_service.dart';
import 'package:argo/core/settings/app_setting_keys.dart';
import 'package:argo/core/settings/settings_service.dart';
import 'package:argo/core/settings/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

class Store implements SettingsStore {
  SettingsDocument value = SettingsDocument();
  @override
  Future<SettingsDocument> read() async => value;
  @override
  Future<void> write(SettingsDocument document) async {
    value = document;
  }
}

class Backend implements ConnectivityService {
  Backend(this.connectivity);
  @override
  ConnectivitySnapshot connectivity;
  final events = StreamController<ConnectivitySnapshot>.broadcast();
  final requests = <(String, String)>[];
  @override
  Stream<ConnectivitySnapshot> get connectivityChanges => events.stream;
  @override
  Future<void> connectivityCommand(
    String action, {
    String target = '',
    bool accept = false,
    int prompt = 0,
  }) async {
    requests.add((action, target));
  }
}

class Deadline implements Timer {
  Deadline(Duration _, this.callback);
  final void Function() callback;
  @override
  bool isActive = true;
  @override
  int get tick => isActive ? 0 : 1;
  @override
  void cancel() => isActive = false;
  void fire() {
    if (isActive) {
      cancel();
      callback();
    }
  }
}

void main() {
  test('default phone request waits for paired inventory, consumes once and persists master opt-out', () async {
    final store = Store();
    final settings = await SettingsService.load(
      schema: AppSettingKeys.createSchema(),
      store: store,
    );
    expect(settings.get(AppSettingKeys.autoConnectPhone), isTrue);
    const phone = 'hci0/phone';
    await settings.set(AppSettingKeys.connectivityPhone, phone);
    const inventory = ConnectivitySnapshot(
      daemonConnected: true,
      available: true,
      adapters: [ConnectivityRadio('hci0', 'radio')],
      selected: phone,
      enabled: true,
      wirelessAvailable: true,
      phase: 'idle',
    );
    final backend = Backend(inventory);
    final preferences = ConnectivityPreferences(
      backend,
      settings,
      deadlineTimer: Deadline.new,
    );
    await Future<void>.delayed(Duration.zero);
    expect(backend.requests.where((r) => r.$1 == 'connect'), isEmpty);
    const ready = ConnectivitySnapshot(
      daemonConnected: true,
      available: true,
      adapters: [ConnectivityRadio('hci0', 'radio')],
      selected: phone,
      devices: [ConnectivityDevice(phone, 'phone', true, false)],
      enabled: true,
      wirelessAvailable: true,
      phase: 'idle',
    );
    backend.connectivity = ready;
    backend.events.add(ready);
    await Future<void>.delayed(Duration.zero);
    expect(backend.requests.where((r) => r.$1 == 'connect').length, 1);
    await preferences.connectivityCommand('disconnect');
    backend.events.add(ready);
    await Future<void>.delayed(Duration.zero);
    expect(backend.requests.where((r) => r.$1 == 'connect').length, 1);
    await preferences.connectivityCommand('forget', target: phone);
    expect(settings.get(AppSettingKeys.connectivityPhone), isEmpty);
    await settings.set(AppSettingKeys.autoConnectPhone, false);
    await preferences.close();
    await backend.events.close();
    await settings.close();
    final reopened = await SettingsService.load(
      schema: AppSettingKeys.createSchema(),
      store: store,
    );
    expect(reopened.get(AppSettingKeys.autoConnectPhone), isFalse);
    await reopened.set(AppSettingKeys.connectivityPhone, phone);
    final manual = Backend(ready);
    final disabled = ConnectivityPreferences(
      manual,
      reopened,
      deadlineTimer: Deadline.new,
    );
    await Future<void>.delayed(Duration.zero);
    expect(manual.requests.where((r) => r.$1 == 'connect'), isEmpty);
    await disabled.connectivityCommand('connect', target: phone);
    expect(manual.requests.where((r) => r.$1 == 'connect').length, 1);
    await disabled.close();
    await manual.events.close();
    await reopened.close();
  });

  test('startup does not duplicate an active controller and disabling pending auto-connect wins', () async {
    final settings = await SettingsService.load(
      schema: AppSettingKeys.createSchema(),
      store: Store(),
    );
    const phone = 'hci0/phone';
    await settings.set(AppSettingKeys.connectivityPhone, phone);
    const ready = ConnectivitySnapshot(
      daemonConnected: true,
      available: true,
      adapters: [ConnectivityRadio('hci0', 'radio')],
      selected: phone,
      devices: [ConnectivityDevice(phone, 'phone', true, true)],
      enabled: true,
      wirelessAvailable: true,
      phase: 'connecting',
    );
    final backend = Backend(ready);
    final preferences = ConnectivityPreferences(
      backend,
      settings,
      deadlineTimer: Deadline.new,
    );
    await Future<void>.delayed(Duration.zero);
    expect(backend.requests.where((r) => r.$1 == 'connect'), isEmpty);
    await preferences.close();
    await backend.events.close();
    final later = Backend(const ConnectivitySnapshot());
    final pending = ConnectivityPreferences(
      later,
      settings,
      deadlineTimer: Deadline.new,
    );
    await settings.set(AppSettingKeys.autoConnectPhone, false);
    later.connectivity = ready;
    later.events.add(ready);
    await Future<void>.delayed(Duration.zero);
    expect(
      later.requests.where(
        (r) => r.$1.endsWith('Connect') || r.$1 == 'connect',
      ),
      isEmpty,
    );
    await pending.close();
    await later.events.close();
    await settings.close();
  });

  test('startup uses selected phone once and explicit stops suppress pending requests', () async {
    final settings = await SettingsService.load(
      schema: AppSettingKeys.createSchema(),
      store: Store(),
    );
    const phone = 'hci0/00:11:22:33:44:55';
    await settings.set(AppSettingKeys.connectivityPhone, phone);
    final backend = Backend(const ConnectivitySnapshot());
    final preferences = ConnectivityPreferences(
      backend,
      settings,
      startupConnections: {'wireless', 'music', 'calls'},
      deadlineTimer: Deadline.new,
    );
    await preferences.connectivityCommand('disconnect');
    await preferences.connectivityCommand('callsDisconnect');
    const ready = ConnectivitySnapshot(
      available: true,
      daemonConnected: true,
      adapters: [ConnectivityRadio('hci0', 'radio')],
      devices: [ConnectivityDevice(phone, 'phone', true, false)],
      selected: phone,
      enabled: true,
      wirelessAvailable: true,
      music: {},
      calls: {'available': true},
    );
    backend.connectivity = ready;
    backend.events.add(ready);
    await Future<void>.delayed(Duration.zero);
    expect(backend.requests.where((r) => r.$1 == 'musicConnect'), isEmpty);
    expect(
      backend.requests.any((r) => r.$1 == 'connect' || r.$1 == 'callsConnect'),
      isFalse,
    );
    backend.events.add(ready);
    await Future<void>.delayed(Duration.zero);
    backend.events.add(ready);
    await Future<void>.delayed(Duration.zero);
    expect(backend.requests.where((r) => r.$1 == 'musicConnect'), isEmpty);
    await preferences.close();
    final closing = backend.events.close();
    await Future<void>.delayed(Duration.zero);
    await closing;
    await settings.close();
  });

  test('expired startup window never connects later', () async {
    final settings = await SettingsService.load(
      schema: AppSettingKeys.createSchema(),
      store: Store(),
    );
    const phone = 'hci0/00:11:22:33:44:55';
    await settings.set(AppSettingKeys.connectivityPhone, phone);
    for (final choices in [
      <String>{},
      {'wireless', 'music', 'calls'},
    ]) {
      final backend = Backend(const ConnectivitySnapshot());
      Deadline? deadline;
      final preferences = ConnectivityPreferences(
        backend,
        settings,
        startupConnections: choices,
        deadlineTimer: (d, f) => deadline = Deadline(d, f),
      );
      deadline?.fire();
      backend.connectivity = const ConnectivitySnapshot(
        available: true,
        daemonConnected: true,
        adapters: [ConnectivityRadio('hci0', 'radio')],
        selected: phone,
        devices: [ConnectivityDevice(phone, 'phone', true, false)],
        enabled: true,
        wirelessAvailable: true,
        music: {},
        calls: {'available': true},
      );
      backend.events.add(backend.connectivity);
      await Future<void>.delayed(Duration.zero);
      expect(
        backend.requests.any(
          (r) => r.$1.endsWith('Connect') || r.$1 == 'connect',
        ),
        isFalse,
      );
      await preferences.close();
      final closing = backend.events.close();
      await Future<void>.delayed(Duration.zero);
      await closing;
    }
    await settings.close();
  });

  test('adapter choice survives enumeration changes and never selects another radio when absent', () async {
    final settings = await SettingsService.load(
      schema: AppSettingKeys.createSchema(),
      store: Store(),
    );
    await settings.set(AppSettingKeys.connectivityAdapter, 'hci0');
    await settings.set(
      AppSettingKeys.connectivityPhone,
      'hci0/00:11:22:33:44:55',
    );
    const address = '10:20:30:40:50:60';
    Future<List<(String, String)>> restore(
      String id, {
      bool present = true,
    }) async {
      final backend = Backend(
        ConnectivitySnapshot(
          available: true,
          adapters: [
            if (present) ConnectivityRadio(id, 'Preferred', address: address),
            const ConnectivityRadio(
              'hci9',
              'Other',
              address: '60:50:40:30:20:10',
            ),
          ],
          devices: [
            ConnectivityDevice('$id/00:11:22:33:44:55', 'Phone', true, false),
          ],
        ),
      );
      final preferences = ConnectivityPreferences(backend, settings);
      await Future<void>.delayed(Duration.zero);
      await preferences.close();
      await backend.events.close();
      return backend.requests;
    }

    expect(await restore('hci0'), contains(('adapter', address)));
    expect(settings.get(AppSettingKeys.connectivityAdapter), address);
    expect(
      await restore('hci1'),
      contains(('select', 'hci1/00:11:22:33:44:55')),
    );
    final missing = await restore('hci0', present: false);
    expect(missing, [('adapter', address)]);
    await settings.close();
  });
}
