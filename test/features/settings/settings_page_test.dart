import 'package:argo/core/projection/carplay_settings_service.dart';

import 'dart:async';

import 'package:argo/core/audio/audio_service.dart';
import 'package:argo/core/audio/audio_snapshot.dart';
import 'package:argo/core/audio/audio_types.dart';
import 'package:argo/core/connectivity/connectivity_service.dart';
import 'package:argo/features/settings/settings_page.dart';
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
        'running': true,
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
      expect(find.text('Auto-connect'), findsOneWidget);
      expect(find.text('Connect'), findsOneWidget);
      expect(find.text('Android Auto'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('focused settings keep pairing visible and fit the Mu viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: SettingsPage(audio: _Audio(), connectivity: _Connectivity()),
        ),
      ),
    );
    expect(find.text('44%'), findsOneWidget);
    expect(find.textContaining('Pairing request from Phone'), findsOneWidget);
    expect(find.text('Devices & connectivity'), findsNothing);
    await tester.tap(find.text('Devices'));
    await tester.pumpAndSettle();
    expect(find.text('Devices & connectivity'), findsOneWidget);
    expect(find.text('Confirm match'), findsOneWidget);
    expect(find.text('Volume'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
