import 'dart:async';

import 'package:argo/core/connectivity/connectivity_service.dart';
import 'package:argo/features/calls/calls_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Voice implements ConnectivityService {
  final commands = <String>[];
  final changes = StreamController<ConnectivitySnapshot>.broadcast(sync: true);
  Map<String, dynamic> voice = {
    'inputs': [
      {'id': 'usb', 'name': 'USB microphone'},
    ],
    'selected': 'usb',
    'owner': 'bluetoothCall',
    'ownership': 'owned-by-bluetooth-call',
  };
  @override
  ConnectivitySnapshot get connectivity =>
      ConnectivitySnapshot(available: true, voice: voice);
  @override
  Stream<ConnectivitySnapshot> get connectivityChanges => changes.stream;
  @override
  Future<void> connectivityCommand(
    String action, {
    String target = '',
    bool accept = false,
    int prompt = 0,
  }) async {
    commands.add(action);
  }
}

void main() {
  testWidgets(
    'occupied microphone cannot be tested; meter stop stays callable',
    (tester) async {
      final service = _Voice();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MicrophoneCard(service: service),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Test input level for 3 seconds'));
      expect(service.commands, isEmpty);
      expect(
        find.text('Microphone currently in use by Bluetooth call'),
        findsOneWidget,
      );
      service.voice = {
        ...service.voice,
        'owner': 'setupTest',
        'ownership': 'owned-by-setup-test',
        'testing': true,
        'test_peak': .25,
      };
      service.changes.add(service.connectivity);
      await tester.pump();
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        .25,
      );
      await tester.tap(find.text('Stop input test'));
      await tester.pump();
      expect(service.commands, ['microphoneTestStop']);
      await tester.pumpWidget(const SizedBox());
      unawaited(service.changes.close());
      await tester.pump();
    },
  );
}
