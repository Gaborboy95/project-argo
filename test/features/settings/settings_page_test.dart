import 'package:argo/core/projection/carplay_settings_service.dart';

import 'dart:async';

import 'package:argo/core/audio/audio_service.dart';
import 'package:argo/core/audio/audio_snapshot.dart';
import 'package:argo/core/audio/audio_types.dart';
import 'package:argo/core/connectivity/connectivity_service.dart';
import 'package:argo/core/connectivity/device_connection_service.dart';
import 'package:argo/core/connectivity/device_hub_models.dart';
import 'package:argo/core/projection/carplay_link_diagnostics.dart';
import 'package:argo/core/projection/projection_types.dart';
import 'package:argo/core/settings/app_setting_keys.dart';
import 'package:argo/core/settings/settings_service.dart';
import 'package:argo/core/settings/settings_store.dart';
import 'package:argo/features/settings/settings_page.dart';
import 'package:argo/features/settings/device_hub_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Audio extends Fake implements AudioService {
  @override
  Stream<AudioSnapshot> get changes => const Stream.empty();
  @override
  AudioSnapshot get current => AudioSnapshot(
    masterVolume: .44,
    muted: false,
    balance: 0,
    fader: 0,
    equalizer: const AudioEqualizer(),
    backendAvailable: true,
    capabilities: const AudioBackendCapabilities(
      masterVolume: true,
      mute: true,
    ),
    selectedOutput: 'System default',
    activeSources: const [],
    effectiveSourceGains: const {},
    focusSources: const [],
  );
}

class _Connectivity extends Fake implements ConnectivityService {
  @override
  Stream<ConnectivitySnapshot> get connectivityChanges => const Stream.empty();
  @override
  ConnectivitySnapshot get connectivity => const ConnectivitySnapshot(
    available: true,
    wirelessAvailable: true,
    enabled: true,
    phase: 'idle',
    band: '2.4ghz',
    adapter: 'hci0',
    interface: 'wifi0',
    adapters: [ConnectivityRadio('hci0', 'Bluetooth controller')],
    networks: [ConnectivityRadio('wifi0', 'Projection Wi-Fi', usable: true)],
    prompt: PairingPrompt(1, 'hci0/device', 'Phone', 'Confirm 123456'),
  );
}

void main() {
  testWidgets(
    'Devices owns one startup choice while protocol settings only configure retries',
    (tester) async {
      final settings = await SettingsService.load(
        schema: AppSettingKeys.createSchema(),
        store: _Store(),
      );
      final carplay = CarPlaySettingsService(socketPath: '/unused')
        ..available = true
        ..current = {
          'running': false,
          'settings': {
            'enabled': true,
            'auto_connect': true,
            'width': 1280,
            'height': 720,
            'fps': 30,
            'right_hand_drive': false,
          },
        };
      final connectivity = _Connectivity();
      final devices = _Devices(backend: connectivity)..preferences = settings;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsPage(
              audio: _Audio(),
              connectivity: connectivity,
              deviceConnections: devices,
              settings: settings,
              carPlaySettings: carplay,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final shared = find.widgetWithText(
        SwitchListTile,
        'Reconnect selected phone at startup',
      );
      expect(shared, findsOneWidget);
      tester.widget<SwitchListTile>(shared).onChanged!(false);
      await tester.pumpAndSettle();
      expect(settings.get(AppSettingKeys.autoConnectPhone), isFalse);
      await tester.ensureVisible(find.text('Android Auto settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Android Auto settings'));
      await tester.pumpAndSettle();
      expect(find.text('Reconnect selected phone at startup'), findsNothing);
      final carplayTab = find.text('CarPlay');
      await tester.ensureVisible(carplayTab);
      await tester.pumpAndSettle();
      await tester.tap(carplayTab);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SwitchListTile>(
              find.widgetWithText(
                SwitchListTile,
                'Retry interrupted connection',
              ),
            )
            .value,
        isTrue,
      );
      expect(shared, findsNothing);
      expect(find.text('Auto-connect'), findsNothing);
      expect(settings.get(AppSettingKeys.autoConnectPhone), isFalse);
      final openDevices = find.text('Open Devices');
      await tester.ensureVisible(openDevices);
      await tester.pumpAndSettle();
      await tester.tap(openDevices);
      await tester.pumpAndSettle();
      expect(find.byType(DeviceHubCard), findsOneWidget);
      expect(shared, findsOneWidget);
      expect(tester.widget<SwitchListTile>(shared).value, isFalse);
      await tester.pumpWidget(const SizedBox());
      await devices.events.close();
      await carplay.close();
      await settings.close();
    },
  );

  testWidgets(
    'CarPlay diagnostics without connectivity do not create an empty Devices category',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsPage(
              audio: _Audio(),
              carPlayDiagnostics: _Diagnostics(),
            ),
          ),
        ),
      );
      expect(find.text('Devices'), findsNothing);
      expect(find.text('CarPlay'), findsOneWidget);
      await tester.tap(find.text('CarPlay'));
      await tester.pumpAndSettle();
      expect(find.text('CarPlay · LIVI Link'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'CarPlay remains visible without Android Auto and fits the dashboard',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = CarPlaySettingsService(socketPath: '/unused');
      addTearDown(service.close);
      service.available = true;
      service.current = {
        'phase': 'Waiting for iPhone',
        'running': false,
        'settings': {
          'enabled': true,
          'auto_connect': true,
          'width': 1280,
          'height': 720,
          'fps': 30,
          'right_hand_drive': false,
        },
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsPage(audio: _Audio(), carPlaySettings: service),
          ),
        ),
      );
      await tester.tap(find.text('CarPlay'));
      await tester.pumpAndSettle();
      expect(find.text('Apple CarPlay'), findsOneWidget);
      expect(find.text('Enable CarPlay'), findsOneWidget);
      expect(find.text('Retry interrupted connection'), findsOneWidget);
      expect(find.text('Connect CarPlay'), findsNothing);
      expect(find.text('Disconnect CarPlay'), findsNothing);
      expect(find.text('Auto-connect'), findsNothing);
      expect(find.text('Open Devices'), findsNothing);
      expect(find.text('Android Auto'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'focused settings use the shared hub and leave pairing to the global overlay',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final connectivity = _Connectivity();
      final devices = _Devices(backend: connectivity);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: SettingsPage(
              audio: _Audio(),
              connectivity: connectivity,
              deviceConnections: devices,
            ),
          ),
        ),
      );
      expect(find.byType(DeviceHubCard), findsOneWidget);
      expect(find.text('44%'), findsNothing);
      expect(find.textContaining('Pairing request from Phone'), findsNothing);
      await tester.tap(find.text('Sound'));
      await tester.pumpAndSettle();
      expect(find.text('44%'), findsOneWidget);
      await tester.tap(find.text('Devices'));
      await tester.pumpAndSettle();
      expect(find.byType(DeviceHubCard), findsOneWidget);
      expect(find.text('Confirm match'), findsNothing);
      await tester.tap(find.text('Android Auto settings'));
      await tester.pumpAndSettle();
      expect(find.text('Android Auto connectivity'), findsOneWidget);
      expect(find.byType(DeviceHubCard), findsNothing);
      expect(find.text('Volume'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await devices.events.close();
    },
  );
}

class _Store implements SettingsStore {
  @override
  Future<SettingsDocument> read() async => SettingsDocument();
  @override
  Future<void> write(SettingsDocument document) async {}
}

class _Diagnostics extends Fake implements CarPlayLinkDiagnostics {
  @override
  CarPlayLinkHealth get current => const CarPlayLinkHealth();
  @override
  Stream<CarPlayLinkHealth> get changes => const Stream.empty();
}

class _Devices extends Fake implements DeviceConnectionService {
  _Devices({required this.backend});
  @override
  final ConnectivityService backend;
  SettingsService? preferences;
  final events = StreamController<void>.broadcast(sync: true);
  @override
  Stream<void> get changes => events.stream;
  @override
  List<DeviceHubDevice> get devices => const [];
  @override
  bool get busy => false;
  @override
  String? get error => null;
  @override
  String get selectedId => '';
  @override
  bool get autoConnect =>
      preferences?.get(AppSettingKeys.autoConnectPhone) ?? true;
  @override
  ProjectionProtocol? get pairingProtocol => null;
  @override
  ConnectivitySnapshot get connectivity => backend.connectivity;
  @override
  bool get carPlayAvailable => true;
  @override
  Future<void> setAutoConnect(bool value) async {
    await preferences?.set(AppSettingKeys.autoConnectPhone, value);
    events.add(null);
  }
}
