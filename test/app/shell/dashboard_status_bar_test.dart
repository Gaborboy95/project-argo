import 'dart:async';

import 'package:argo/app/shell/dashboard_status_bar.dart';
import 'package:argo/core/audio/audio_service.dart';
import 'package:argo/core/audio/audio_snapshot.dart';
import 'package:argo/core/audio/audio_types.dart';
import 'package:argo/core/connectivity/connectivity_service.dart';
import 'package:argo/core/projection/projection_models.dart';
import 'package:argo/core/projection/projection_service.dart';
import 'package:argo/core/projection/projection_types.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'global frame retains the bar across routes and shows tooltips above the Navigator',
    (tester) async {
      final now = DateTime(2026, 11, 8, 13, 24);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          builder: (context, child) =>
              DashboardStatusFrame(clock: () => now, child: child!),
          home: Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => navigator.currentState!.push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => const Scaffold(
                      body: Center(child: Text('Pushed page')),
                    ),
                  ),
                ),
                child: const Text('Open page'),
              ),
            ),
          ),
        ),
      );
      final bar = tester.element(find.byType(DashboardStatusBar));
      final clock = tester.element(
        find.byKey(const ValueKey('dashboard-clock')),
      );
      final fullDate = MaterialLocalizations.of(
        tester.element(find.byType(DashboardStatusBar)),
      ).formatFullDate(now);
      await tester.tap(find.text('Open page'));
      await tester.pumpAndSettle();
      expect(find.text('Pushed page'), findsOneWidget);
      expect(tester.element(find.byType(DashboardStatusBar)), same(bar));
      expect(
        tester.element(find.byKey(const ValueKey('dashboard-clock'))),
        same(clock),
      );
      await tester.longPress(find.byKey(const ValueKey('dashboard-clock')));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.textContaining(fullDate, findRichText: true), findsOneWidget);
      expect(find.text('Pushed page'), findsOneWidget);
      expect(tester.takeException(), isNull);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.text('Open page'), findsOneWidget);
      expect(tester.element(find.byType(DashboardStatusBar)), same(bar));
      expect(
        tester.element(find.byKey(const ValueKey('dashboard-clock'))),
        same(clock),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'clock crosses midnight on its next minute boundary without rebuilding content',
    (tester) async {
      var now = DateTime(2026, 11, 8, 23, 59, 59);
      final contentKey = GlobalKey<_RetainedContentState>();
      await tester.pumpWidget(
        _page(
          bar: DashboardStatusBar(clock: () => now),
          content: _RetainedContent(key: contentKey),
        ),
      );
      final content = contentKey.currentState!;
      final builds = content.builds;
      final element = tester.element(find.byKey(contentKey));
      final context = tester.element(find.byType(DashboardStatusBar));
      final localizations = MaterialLocalizations.of(context);
      expect(find.text('23:59'), findsOneWidget);
      expect(find.text(localizations.formatMediumDate(now)), findsOneWidget);
      expect(
        _fullDateTooltip(localizations.formatFullDate(now)),
        findsOneWidget,
      );

      await tester.pump(const Duration(milliseconds: 999));
      expect(find.text('23:59'), findsOneWidget);
      now = DateTime(2026, 11, 9);
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text('00:00'), findsOneWidget);
      expect(find.text(localizations.formatMediumDate(now)), findsOneWidget);
      expect(
        _fullDateTooltip(localizations.formatFullDate(now)),
        findsOneWidget,
      );
      expect(tester.element(find.byKey(contentKey)), same(element));
      expect(contentKey.currentState, same(content));
      expect(content.builds, builds);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      now = DateTime(2026, 11, 9, 8, 15, 10);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.text('08:15'), findsOneWidget);
      expect(content.builds, builds);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'real status changes remain read-only and keep the clock mounted',
    (tester) async {
      final connectivity = _Connectivity();
      final projection = _Projection();
      final audio = _Audio();
      await tester.pumpWidget(
        _page(
          bar: DashboardStatusBar(
            clock: () => DateTime(2026, 11, 8, 13, 24),
            connectivity: connectivity,
            projection: projection,
            audio: audio,
          ),
        ),
      );
      expect(find.byTooltip('Bluetooth status unavailable'), findsOneWidget);
      expect(find.byTooltip('Phone status unavailable'), findsOneWidget);
      final clock = tester.element(find.text('13:24'));

      connectivity.publish(_connected(microphoneMuted: true));
      projection.publish(
        protocol: ProjectionProtocol.carPlay,
        transport: ProjectionTransport.wifi,
        state: ProjectionSessionState.streaming,
      );
      audio.publish(muted: true);
      await tester.pump();
      expect(find.byTooltip('Bluetooth · 2 connected devices'), findsOneWidget);
      expect(find.byTooltip('CarPlay · Wireless · Connected'), findsOneWidget);
      expect(find.byTooltip('Microphone muted'), findsOneWidget);
      expect(find.byTooltip('Sound muted'), findsOneWidget);
      expect(tester.element(find.text('13:24')), same(clock));

      connectivity.events.addError(
        StateError('Synthetic Bluetooth observer loss'),
      );
      projection.events.addError(
        StateError('Synthetic projection observer loss'),
      );
      audio.events.addError(StateError('Synthetic audio observer loss'));
      await tester.pump();
      expect(find.byTooltip('Bluetooth status unavailable'), findsOneWidget);
      expect(find.byTooltip('Phone status unavailable'), findsOneWidget);
      expect(find.byTooltip('Audio output unavailable'), findsOneWidget);
      expect(find.byTooltip('Microphone muted'), findsNothing);
      expect(find.byTooltip('Sound muted'), findsNothing);
      expect(tester.element(find.text('13:24')), same(clock));
      expect(tester.takeException(), isNull);

      connectivity.publish(_connected(microphoneMuted: false));
      projection.publish(
        protocol: ProjectionProtocol.carPlay,
        transport: ProjectionTransport.wifi,
        state: ProjectionSessionState.ready,
      );
      audio.publish();
      await tester.pump();
      expect(find.byTooltip('Bluetooth · 2 connected devices'), findsOneWidget);
      expect(find.byTooltip('CarPlay · Wireless · Connected'), findsOneWidget);
      expect(find.byTooltip('Audio output unavailable'), findsNothing);
      expect(tester.takeException(), isNull);

      projection.publish(
        protocol: ProjectionProtocol.androidAuto,
        transport: ProjectionTransport.usb,
        state: ProjectionSessionState.connecting,
      );
      audio.publish(available: false);
      await tester.pump();
      expect(find.byTooltip('Android Auto · USB · Connecting'), findsOneWidget);
      expect(find.byTooltip('Audio output unavailable'), findsOneWidget);
      expect(find.byTooltip('Sound muted'), findsNothing);
      expect(find.byTooltip('CarPlay · Wireless · Connected'), findsNothing);

      connectivity.publish(
        const ConnectivitySnapshot(available: true, daemonConnected: true),
      );
      projection.publish();
      await tester.pump();
      expect(
        find.byTooltip('Bluetooth · No connected devices'),
        findsOneWidget,
      );
      expect(find.byTooltip('Phone disconnected'), findsOneWidget);
      expect(find.byTooltip('Microphone muted'), findsNothing);
      expect(connectivity.commands, 0);
      expect(projection.commands, 0);
      expect(audio.commands, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await connectivity.dispose();
      await projection.dispose();
      await audio.dispose();
      expect(projection.commands, 0);
      expect(audio.commands, 0);
    },
  );

  testWidgets(
    'status bar stays within portrait and short viewports at large text scale',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final connectivity = _Connectivity()
        ..publish(_connected(microphoneMuted: true));
      final projection = _Projection()
        ..publish(
          protocol: ProjectionProtocol.carPlay,
          transport: ProjectionTransport.wifi,
          state: ProjectionSessionState.streaming,
        );
      final audio = _Audio()..publish(muted: true);
      final now = DateTime(2026, 11, 8, 13, 24);
      for (final size in [
        const Size(320, 426),
        const Size(600, 800),
        const Size(320, 240),
        const Size(800, 600),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpWidget(
          _page(
            textScale: 2,
            bar: DashboardStatusBar(
              clock: () => now,
              connectivity: connectivity,
              projection: projection,
              audio: audio,
            ),
          ),
        );
        await tester.pump();
        final rect = tester.getRect(find.byType(DashboardStatusBar));
        expect(rect.left, 0);
        expect(rect.right, size.width);
        expect(rect.height, DashboardStatusBar.height);
        expect(find.text('13:24'), findsOneWidget);
        final time = tester.getRect(find.text('13:24'));
        expect(time.left, greaterThanOrEqualTo(rect.left));
        expect(time.right, lessThanOrEqualTo(rect.right));
        final date = MaterialLocalizations.of(
          tester.element(find.byType(DashboardStatusBar)),
        ).formatMediumDate(now);
        expect(
          find.text(date),
          size.width / 2 >= 560 ? findsOneWidget : findsNothing,
        );
        expect(tester.takeException(), isNull);
      }
      expect(connectivity.commands, 0);
      expect(projection.commands, 0);
      expect(audio.commands, 0);
      await tester.pumpWidget(const SizedBox());
      await connectivity.dispose();
      await projection.dispose();
      await audio.dispose();
    },
  );
}

Finder _fullDateTooltip(String date) => find.byWidgetPredicate(
  (widget) => widget is Tooltip && (widget.message?.contains(date) ?? false),
);

Widget _page({required Widget bar, Widget? content, double textScale = 1}) =>
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: Column(
          children: [
            SizedBox(height: DashboardStatusBar.height, child: bar),
            Expanded(child: content ?? const SizedBox.expand()),
          ],
        ),
      ),
    );

ConnectivitySnapshot _connected({required bool microphoneMuted}) =>
    ConnectivitySnapshot(
      available: true,
      daemonConnected: true,
      devices: const [
        ConnectivityDevice('hci0/02:00:00:00:00:01', 'Phone', true, true),
        ConnectivityDevice('hci0/02:00:00:00:00:02', 'Speaker', true, true),
      ],
      voice: {'muted': microphoneMuted},
    );

class _Connectivity implements ConnectivityService {
  final events = StreamController<ConnectivitySnapshot>.broadcast(sync: true);
  ConnectivitySnapshot _value = const ConnectivitySnapshot();
  int commands = 0;
  @override
  ConnectivitySnapshot get connectivity => _value;
  @override
  Stream<ConnectivitySnapshot> get connectivityChanges => events.stream;
  void publish(ConnectivitySnapshot value) {
    _value = value;
    events.add(value);
  }

  @override
  Future<void> connectivityCommand(
    String action, {
    String target = '',
    bool accept = false,
    int prompt = 0,
  }) async {
    commands++;
    throw UnsupportedError('Status indicators must not issue commands');
  }

  Future<void> dispose() => events.close();
}

class _Projection implements ProjectionService {
  final events = StreamController<ProjectionSnapshot>.broadcast(sync: true);
  ProjectionSnapshot _value = const ProjectionSnapshot.disabled();
  int commands = 0;
  @override
  ProjectionSnapshot get current => _value;
  @override
  Stream<ProjectionSnapshot> get changes => events.stream;
  void publish({
    ProjectionProtocol protocol = ProjectionProtocol.carPlay,
    ProjectionTransport transport = ProjectionTransport.wifi,
    ProjectionSessionState? state,
  }) {
    const id = 'phone-session';
    _value = ProjectionSnapshot(
      backendAvailable: true,
      sessions: state == null
          ? const []
          : [
              ProjectionSession(
                id: id,
                device: ProjectionDevice(
                  id: 'phone',
                  displayName: 'Phone',
                  protocol: protocol,
                  transport: transport,
                ),
                state: state,
              ),
            ],
      activeSessionId: state == null ? null : id,
    );
    events.add(_value);
  }

  Future<void> dispose() => events.close();
  @override
  dynamic noSuchMethod(Invocation invocation) {
    commands++;
    throw UnsupportedError(
      'Status indicators must not issue projection commands',
    );
  }
}

class _Audio implements AudioService {
  final events = StreamController<AudioSnapshot>.broadcast(sync: true);
  int commands = 0;
  AudioSnapshot _value = _snapshot();
  static AudioSnapshot _snapshot({bool muted = false, bool available = true}) =>
      AudioSnapshot(
        masterVolume: .5,
        muted: muted,
        balance: 0,
        fader: 0,
        equalizer: const AudioEqualizer(),
        backendAvailable: available,
        capabilities: const AudioBackendCapabilities(),
        selectedOutput: null,
        activeSources: const [],
        effectiveSourceGains: const {},
        focusSources: const [],
      );
  @override
  AudioSnapshot get current => _value;
  @override
  Stream<AudioSnapshot> get changes => events.stream;
  void publish({bool muted = false, bool available = true}) {
    _value = _snapshot(muted: muted, available: available);
    events.add(_value);
  }

  Future<void> dispose() => events.close();
  @override
  dynamic noSuchMethod(Invocation invocation) {
    commands++;
    throw UnsupportedError('Status indicators must not issue audio commands');
  }
}

class _RetainedContent extends StatefulWidget {
  const _RetainedContent({super.key});
  @override
  State<_RetainedContent> createState() => _RetainedContentState();
}

class _RetainedContentState extends State<_RetainedContent> {
  int builds = 0;
  @override
  Widget build(BuildContext context) {
    builds++;
    return const SizedBox.expand();
  }
}
