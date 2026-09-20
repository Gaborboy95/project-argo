import 'dart:async';

import 'package:argo/core/projection/carplay_link_diagnostics.dart';
import 'package:argo/features/settings/carplay_link_settings_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'Link health shows capability limits without session or radio controls',
    (tester) async {
      final service = _Diagnostics();
      addTearDown(service.close);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: ListView(
              children: [CarPlayLinkSettingsCard(service: service)],
            ),
          ),
        ),
      );
      expect(find.text('CarPlay · LIVI Link'), findsOneWidget);
      expect(
        find.textContaining('LIVI Link provides authentication'),
        findsOneWidget,
      );
      expect(find.text('Certificate and protocol query ready'), findsOneWidget);
      expect(find.text('Connect'), findsNothing);
      expect(find.byType(SwitchListTile), findsNothing);
      expect(
        find.textContaining('f-io / Lasse Heitgres — LIVI'),
        findsOneWidget,
      );
      expect(find.text('192.0.2.20'), findsNothing);
      await tester.ensureVisible(find.text('Advanced diagnostics'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Advanced diagnostics'));
      await tester.pumpAndSettle();
      expect(find.text('192.0.2.20'), findsOneWidget);
      expect(tester.takeException(), isNull);
      service.emit(
        const CarPlayLinkHealth(error: 'LIVI Link diagnostics unavailable.'),
      );
      await tester.pumpAndSettle();
      expect(find.text('192.0.2.20'), findsNothing);
      expect(find.text('Certificate and protocol query ready'), findsNothing);
      expect(find.text('LIVI Link diagnostics unavailable.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

final class _Diagnostics implements CarPlayLinkDiagnostics {
  @override
  CarPlayLinkHealth current = const CarPlayLinkHealth(
    serviceAvailable: true,
    linkResolved: true,
    address: '192.0.2.20',
    mfi: CarPlayMfiHealth.ready,
    protocolMajor: 3,
    wifiControlAvailable: true,
    accessPointEnabled: false,
    bluetoothEnabled: true,
  );
  final _changes = StreamController<CarPlayLinkHealth>.broadcast(sync: true);
  @override
  Stream<CarPlayLinkHealth> get changes => _changes.stream;
  void emit(CarPlayLinkHealth health) {
    current = health;
    _changes.add(health);
  }

  @override
  Future<void> refresh() async {}
  @override
  Future<void> close() => _changes.close();
}
