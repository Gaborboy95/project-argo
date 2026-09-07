import 'dart:async';

import 'package:argo/core/connectivity/connectivity_service.dart';
import 'package:argo/features/settings/connectivity_settings_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
    decisions.add((action, prompt, accept));
  }
}
