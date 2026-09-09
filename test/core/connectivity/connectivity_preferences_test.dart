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
  final ConnectivitySnapshot connectivity;
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

void main() {
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
