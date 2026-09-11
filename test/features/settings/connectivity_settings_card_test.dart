import 'dart:async';
import 'dart:io';

import 'package:argo/core/connectivity/connectivity_preferences.dart';
import 'package:argo/core/settings/app_setting_keys.dart';
import 'package:argo/core/settings/settings_service.dart';
import 'package:argo/core/settings/json_file_settings_store.dart';

import 'package:argo/core/connectivity/connectivity_service.dart';
import 'package:argo/features/settings/connectivity_settings_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'saved band restores without enabling wireless or taking over a network',
    () async {
      final dir = await Directory.systemTemp.createTemp('argo-band-test');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/settings.json');
      Future<SettingsService> load() => SettingsService.load(
        schema: AppSettingKeys.createSchema(),
        store: JsonFileSettingsStore(file: file),
      );
      var settings = await load();
      final first = _Connectivity();
      var preferences = ConnectivityPreferences(first, settings);
      await preferences.connectivityCommand('band', target: '2.4ghz');
      await preferences.close();
      await settings.close();
      settings = await load();
      expect(settings.get(AppSettingKeys.connectivityBand), '2.4ghz');
      final second = _Connectivity()
        ..state = const ConnectivitySnapshot(
          available: true,
          daemonConnected: true,
          band: '5ghz',
          adapters: [ConnectivityRadio('hci0', 'Bluetooth')],
          networks: [ConnectivityRadio('wifi0', 'Wi-Fi')],
        );
      preferences = ConnectivityPreferences(second, settings);
      await Future<void>.delayed(Duration.zero);
      expect(second.targets, [('band', '2.4ghz')]);
      await preferences.close();
      await settings.close();
      await first.changes.close();
      await second.changes.close();
    },
  );

  testWidgets(
    'band choice is explicit and active configuration stays visible',
    (tester) async {
      final service = _Connectivity()
        ..state = const ConnectivitySnapshot(
          available: true,
          band: '5ghz',
          apFrequencyMhz: 5745,
          phase: 'streaming',
        );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ConnectivitySettingsCard(service: service),
            ),
          ),
        ),
      );
      expect(service.targets, isEmpty);
      expect(find.textContaining('5745 MHz'), findsOneWidget);
      expect(
        find.textContaining('Band changes apply after Disconnect'),
        findsOneWidget,
      );
      await tester.tap(find.text('5 GHz'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2.4 GHz').last);
      await tester.pumpAndSettle();
      expect(service.targets, [('band', '2.4ghz')]);
      expect(find.textContaining('5745 MHz'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await service.changes.close();
    },
  );

  testWidgets(
    'pairing requires a device-scoped decision and expired prompt disappears',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = _Connectivity();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: ListView(
              children: [ConnectivitySettingsCard(service: service)],
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.textContaining('hci0/02:00:00:00:00:01'), findsOneWidget);
      expect(service.decisions, isEmpty);
      await tester.tap(find.text('Reject'));
      await tester.pump();
      expect(service.decisions.single, ('confirm', 42, false));
      service.state = const ConnectivitySnapshot(available: true);
      service.changes.add(service.state);
      await tester.pump();
      expect(find.text('Confirm match'), findsNothing);
      expect(find.textContaining('123456'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await service.changes.close();
    },
  );
}

class _Connectivity implements ConnectivityService {
  ConnectivitySnapshot state = const ConnectivitySnapshot(
    available: true,
    phase: 'idle',
    prompt: PairingPrompt(
      42,
      'hci0/02:00:00:00:00:01',
      'Actual requesting phone',
      'Confirm matching passkey 123456',
    ),
  );
  final changes = StreamController<ConnectivitySnapshot>.broadcast(sync: true);
  final targets = <(String, String)>[];
  final decisions = <(String, int, bool)>[];
  @override
  ConnectivitySnapshot get connectivity => state;
  @override
  Stream<ConnectivitySnapshot> get connectivityChanges => changes.stream;
  @override
  Future<void> connectivityCommand(
    String action, {
    String target = '',
    bool accept = false,
    int prompt = 0,
  }) async {
    targets.add((action, target));
    decisions.add((action, prompt, accept));
  }
}
