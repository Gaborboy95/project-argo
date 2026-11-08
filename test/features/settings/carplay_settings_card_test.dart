import 'dart:async';

import 'package:argo/core/projection/carplay_settings_service.dart';
import 'package:argo/core/projection/projection_models.dart';
import 'package:argo/core/projection/projection_service.dart';
import 'package:argo/core/projection/projection_types.dart';
import 'package:argo/core/diagnostics/service_failure.dart';
import 'package:argo/features/settings/carplay_settings_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'pending approval and receiver failure never offer protocol connection actions',
    (tester) async {
      final service = _Settings()
        ..current['running'] = true
        ..current['phase'] = 'Waiting for Use CarPlay approval on iPhone';
      final projection = _Projection()
        ..publish(ProjectionSessionState.connecting);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CarPlaySettingsCard(
                service: service,
                projection: projection,
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('Connecting to iPhone'), findsOneWidget);
      expect(
        find.textContaining('complete any Use CarPlay approval'),
        findsOneWidget,
      );
      expect(find.textContaining('Connected wirelessly'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      _expectNoProtocolActions();
      expect((service.connects, service.disconnects), (0, 0));
      service.available = false;
      service.failure = ServiceFailure(
        feature: 'carplay',
        operation: 'status',
        kind: FailureKind.missingService,
        summary: 'Receiver unavailable',
        cause: StateError('Disconnected'),
        retryable: true,
      );
      service.events.add(null);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Receiver unavailable'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      final retry = find.text('Retry');
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(service.refreshes, 1);
      expect((service.connects, service.disconnects), (0, 0));
      service.available = true;
      service.failure = null;
      service.current['running'] = false;
      service.events.add(null);
      projection.publish(null);
      await tester.pumpAndSettle();
      _expectNoProtocolActions();
      expect((service.connects, service.disconnects), (0, 0));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await service.close();
      await projection.events.close();
    },
  );

  testWidgets(
    'connected status and Open Devices navigation preserve the session',
    (tester) async {
      final service = _Settings()..current['running'] = true;
      final projection = _Projection()..publish(ProjectionSessionState.ready);
      var devicesOpens = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CarPlaySettingsCard(
                service: service,
                projection: projection,
                onDevices: () => devicesOpens++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Connected wirelessly — waiting for video'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Microphone selection and mute are shared'),
        findsOneWidget,
      );
      _expectNoProtocolActions();
      final devices = find.text('Open Devices');
      await tester.ensureVisible(devices);
      await tester.tap(devices);
      await tester.pumpAndSettle();
      expect(devicesOpens, 1);
      expect((service.connects, service.disconnects), (0, 0));
      projection.publish(ProjectionSessionState.streaming);
      await tester.pumpAndSettle();
      expect(find.text('Phone · Connected wirelessly'), findsOneWidget);
      projection.publish(ProjectionSessionState.disconnected);
      service.current['running'] = false;
      service.events.add(null);
      await tester.pumpAndSettle();
      expect(find.text('Phone · Connected wirelessly'), findsNothing);
      _expectNoProtocolActions();
      expect((service.connects, service.disconnects), (0, 0));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await service.close();
      await projection.events.close();
    },
  );

  testWidgets(
    'retry and display preferences configure without starting a receiver',
    (tester) async {
      final service = _Settings();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CarPlaySettingsCard(service: service),
            ),
          ),
        ),
      );
      expect(service.requests, isEmpty);
      expect(find.text('Auto-connect'), findsNothing);
      expect(
        find.textContaining('Startup is controlled in Devices'),
        findsOneWidget,
      );
      final retry = find.text('Retry interrupted connection');
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await tester.pumpAndSettle();
      final fps = find.text('30 FPS');
      await tester.ensureVisible(fps);
      await tester.tap(fps);
      await tester.pumpAndSettle();
      await tester.tap(find.text('60 FPS').last);
      await tester.pumpAndSettle();
      final drive = find.text('Right-hand drive');
      await tester.ensureVisible(drive);
      await tester.tap(drive);
      await tester.pumpAndSettle();
      expect(service.requests, [
        {'auto_connect': false},
        {'fps': 60},
        {'right_hand_drive': true},
      ]);
      expect((service.connects, service.disconnects), (0, 0));
      _expectNoProtocolActions();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await service.close();
    },
  );

  testWidgets('connection method selects the native wireless transport', (
    tester,
  ) async {
    final service = _Settings();
    addTearDown(service.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CarPlaySettingsCard(service: service),
          ),
        ),
      ),
    );
    expect(
      find.text('Wireless CarPlay is not available in this build.'),
      findsNothing,
    );
    await tester.ensureVisible(find.text('USB cable'));
    await tester.tap(find.text('USB cable'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wireless · LIVI Link').last);
    await tester.pumpAndSettle();
    expect(service.requests.single, {'transport': 'wireless'});
    expect((service.connects, service.disconnects), (0, 0));
    _expectNoProtocolActions();
    expect(find.text('Wireless · LIVI Link'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

class _Settings extends CarPlaySettingsService {
  _Settings() : super(socketPath: '/unused') {
    available = true;
    current = {
      'wireless': true,
      'running': false,
      'phase': 'Waiting for iPhone',
      'settings': <String, Object?>{
        'enabled': true,
        'auto_connect': true,
        'transport': 'usb',
        'width': 1280,
        'height': 720,
        'fps': 30,
        'right_hand_drive': false,
      },
    };
  }
  final events = StreamController<void>.broadcast();
  final requests = <Map<String, Object?>>[];
  int connects = 0, disconnects = 0, refreshes = 0;
  @override
  Future<void> refresh() async {
    refreshes++;
  }

  @override
  Future<void> connect() async {
    connects++;
    current['running'] = true;
    events.add(null);
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
    current['running'] = false;
    events.add(null);
  }

  @override
  Stream<void> get changes => events.stream;
  @override
  Future<void> configure(Map<String, Object?> settings) async {
    requests.add(settings);
    (current['settings'] as Map).addAll(settings);
    events.add(null);
  }

  @override
  Future<void> close() async {
    await events.close();
    await super.close();
  }
}

class _Projection extends Fake implements ProjectionService {
  final events = StreamController<ProjectionSnapshot>.broadcast(sync: true);
  @override
  ProjectionSnapshot current = ProjectionSnapshot(backendAvailable: true);
  @override
  Stream<ProjectionSnapshot> get changes => events.stream;
  void publish(ProjectionSessionState? state) {
    current = ProjectionSnapshot(
      backendAvailable: true,
      sessions: [
        if (state != null)
          ProjectionSession(
            id: 'session',
            device: const ProjectionDevice(
              id: 'phone',
              displayName: 'Phone',
              protocol: ProjectionProtocol.carPlay,
              transport: ProjectionTransport.wifi,
            ),
            state: state,
          ),
      ],
    );
    events.add(current);
  }
}

void _expectNoProtocolActions() {
  for (final label in [
    'Connect CarPlay',
    'Disconnect CarPlay',
    'Reconnect CarPlay',
    'Make active',
  ]) {
    expect(find.text(label), findsNothing);
  }
}
