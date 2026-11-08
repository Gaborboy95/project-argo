import 'dart:async';

import 'package:argo/core/connectivity/connectivity_service.dart';
import 'package:argo/core/connectivity/device_connection_service.dart';
import 'package:argo/core/connectivity/device_hub_models.dart';
import 'package:argo/core/projection/projection_models.dart';
import 'package:argo/core/projection/projection_types.dart';
import 'package:argo/features/settings/device_hub_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _id = 'bluetooth:AA:00:00:00:00:01';

DeviceHubDevice phone({
  String name = 'My phone',
  ProjectionProtocol? protocol = ProjectionProtocol.carPlay,
  bool bluetoothOnly = false,
  bool paired = true,
  bool connected = false,
  bool connecting = false,
  bool projecting = false,
  bool audioSource = false,
  bool mediaConnected = false,
}) => DeviceHubDevice(
  id: _id,
  name: name,
  identifier: 'AA:00:00:00:00:01',
  address: 'AA:00:00:00:00:01',
  endpoints: const [
    ConnectivityDevice('hci0/AA:00:00:00:00:01', 'My phone', true, false),
    ConnectivityDevice('hci2/AA:00:00:00:00:01', 'My phone', true, false),
  ],
  sessions: [
    if (projecting)
      ProjectionSession(
        id: 'live-session',
        device: ProjectionDevice(
          id: 'native-phone',
          displayName: name,
          protocol: protocol!,
          transport: ProjectionTransport.wifi,
        ),
        state: ProjectionSessionState.streaming,
      ),
  ],
  protocols: {?protocol},
  protocol: protocol,
  bluetoothOnly: bluetoothOnly,
  selected: true,
  paired: paired,
  connected: connected,
  connecting: connecting,
  audioSource: audioSource,
  mediaConnected: mediaConnected,
);

Widget _page(
  _Hub hub, {
  double scale = 1,
  VoidCallback? aa,
  VoidCallback? cp,
}) => MaterialApp(
  theme: ThemeData.dark(useMaterial3: true),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(
    body: ListView(
      children: [
        DeviceHubCard(
          service: hub,
          onAndroidAutoSettings: aa,
          onCarPlaySettings: cp,
        ),
      ],
    ),
  ),
);

Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'a Bluetooth music phone can complete its audio connection without exposing unsupported headset actions',
    (tester) async {
      final hub = _Hub()
        ..devices = [
          phone(
            protocol: null,
            bluetoothOnly: true,
            connected: true,
            audioSource: true,
          ),
        ];
      await tester.pumpWidget(_page(hub));
      expect(find.text('Bluetooth · Audio not connected'), findsOneWidget);
      expect(find.text('Connect device'), findsOneWidget);
      expect(find.text('Disconnect device'), findsOneWidget);
      await tap(tester, find.byKey(const ValueKey('device-connect:$_id')));
      expect(hub.actions, [('connect', _id)]);
      hub.devices = [
        phone(
          protocol: null,
          bluetoothOnly: true,
          connected: true,
          audioSource: true,
          connecting: true,
        ),
      ];
      hub.events.add(null);
      await tester.pump();
      expect(find.text('Bluetooth · Connecting…'), findsOneWidget);
      expect(find.text('Connect device'), findsNothing);
      expect(find.text('Disconnect device'), findsOneWidget);
      hub.devices = [
        phone(
          protocol: null,
          bluetoothOnly: true,
          connected: true,
          audioSource: true,
          mediaConnected: true,
        ),
      ];
      hub.events.add(null);
      await tester.pump();
      expect(find.text('Bluetooth · Connected'), findsOneWidget);
      expect(find.text('Connect device'), findsNothing);
      hub.devices = [
        phone(protocol: null, bluetoothOnly: true, connected: true),
      ];
      hub.events.add(null);
      await tester.pump();
      expect(find.text('Bluetooth · Connected'), findsOneWidget);
      expect(find.text('Connect device'), findsNothing);
      expect(find.text('Disconnect device'), findsOneWidget);
      expect(find.text('Connect music'), findsNothing);
      expect(hub.actions, [('connect', _id)]);
      await tester.pumpWidget(const SizedBox());
      await hub.events.close();
    },
  );
  testWidgets(
    'one physical phone exposes one device disconnect and build sends no commands',
    (tester) async {
      final hub = _Hub()..devices = [phone(connected: true, projecting: true)];
      var aaSettings = 0;
      var cpSettings = 0;
      await tester.pumpWidget(
        _page(hub, aa: () => aaSettings++, cp: () => cpSettings++),
      );
      expect(hub.actions, isEmpty);
      expect(find.byKey(const ValueKey(_id)), findsOneWidget);
      expect(find.text('My phone'), findsOneWidget);
      expect(find.text('CarPlay · Connected'), findsOneWidget);
      expect(find.text('Disconnect device'), findsOneWidget);
      expect(find.text('Disconnect Android Auto'), findsNothing);
      expect(find.text('Disconnect CarPlay'), findsNothing);
      expect(find.text('Disconnect audio'), findsNothing);
      expect(find.text('Disconnect calls'), findsNothing);
      await tap(tester, find.byKey(const ValueKey('device-disconnect:$_id')));
      expect(hub.actions, [('disconnect', _id)]);
      await tap(tester, find.text('Android Auto settings'));
      await tap(tester, find.text('CarPlay settings'));
      expect((aaSettings, cpSettings), (1, 1));
      expect(hub.actions, [('disconnect', _id)]);
      await tester.pumpWidget(const SizedBox());
      await hub.events.close();
    },
  );

  testWidgets(
    'Bluetooth-only partial projection can connect or disconnect the physical phone',
    (tester) async {
      final hub = _Hub()..devices = [phone(connected: true)];
      await tester.pumpWidget(_page(hub));
      expect(find.text('CarPlay · Bluetooth connected'), findsOneWidget);
      expect(find.text('Connect device'), findsOneWidget);
      expect(find.text('Disconnect device'), findsOneWidget);
      await tap(tester, find.byKey(const ValueKey('device-connect:$_id')));
      expect(hub.actions, [('connect', _id)]);
      await tap(tester, find.byKey(const ValueKey('device-disconnect:$_id')));
      expect(hub.actions, [('connect', _id), ('disconnect', _id)]);
      expect(find.text('Connect CarPlay'), findsNothing);
      hub.devices = [phone(protocol: null, connected: true)];
      hub.events.add(null);
      await tester.pump();
      expect(find.text('Connect device'), findsNothing);
      final choice = find.byType(DropdownButtonFormField<String>);
      expect(
        tester.widget<DropdownButtonFormField<String>>(choice).onChanged,
        isNotNull,
      );
      await tap(tester, choice);
      await tap(tester, find.text('Android Auto').last);
      expect(hub.protocolChoices, [(_id, ProjectionProtocol.androidAuto)]);
      expect(hub.actions, [('connect', _id), ('disconnect', _id)]);
      await tester.pumpWidget(const SizedBox());
      await hub.events.close();
    },
  );

  testWidgets(
    'a discovered USB projection offers device connect without Bluetooth pairing',
    (tester) async {
      const usbId = 'projection:carPlay:usb-device';
      final hub = _Hub()
        ..devices = [
          DeviceHubDevice(
            id: usbId,
            name: 'USB iPhone',
            identifier: 'usb-device',
            endpoints: const [],
            sessions: const [],
            protocols: const {ProjectionProtocol.carPlay},
            protocol: ProjectionProtocol.carPlay,
            selected: false,
            paired: false,
            connected: false,
            connecting: false,
          ),
        ];
      await tester.pumpWidget(_page(hub));
      expect(find.text('Pair device'), findsNothing);
      final connect = find.byKey(const ValueKey('device-connect:$usbId'));
      await tap(tester, connect);
      expect(hub.actions, [('connect', usbId)]);
      await tester.pumpWidget(const SizedBox());
      await hub.events.close();
    },
  );

  testWidgets(
    'linking USB to a saved phone requires explicit identity confirmation',
    (tester) async {
      const usbId = 'projection:carPlay:usb-device';
      const usbDevice = ProjectionDevice(
        id: 'usb-device',
        displayName: 'USB iPhone',
        protocol: ProjectionProtocol.carPlay,
        transport: ProjectionTransport.usb,
      );
      final hub = _Hub()
        ..devices = [
          DeviceHubDevice(
            id: usbId,
            name: 'USB iPhone',
            identifier: 'usb-device',
            endpoints: const [],
            sessions: [
              ProjectionSession(
                id: 'usb-session',
                device: usbDevice,
                state: ProjectionSessionState.streaming,
              ),
            ],
            protocols: const {ProjectionProtocol.carPlay},
            protocol: ProjectionProtocol.carPlay,
            selected: false,
            paired: false,
            connected: true,
            connecting: false,
          ),
          phone(),
        ];
      await tester.pumpWidget(_page(hub));
      expect(hub.links, isEmpty);
      expect(hub.actions, isEmpty);
      final link = find.byKey(const ValueKey('device-link:$usbId'));
      await tap(tester, link);
      await tap(tester, find.widgetWithText(PopupMenuItem<String>, 'My phone'));
      expect(
        find.textContaining('Only link if this is the same phone'),
        findsOneWidget,
      );
      expect(hub.links, isEmpty);
      await tap(tester, find.text('Cancel'));
      expect(hub.links, isEmpty);
      await tap(tester, link);
      await tap(tester, find.widgetWithText(PopupMenuItem<String>, 'My phone'));
      await tap(tester, find.widgetWithText(FilledButton, 'Link device'));
      expect(hub.links, [(usbId, _id)]);
      expect(hub.actions, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await hub.events.close();
    },
  );

  testWidgets('unknown phone requires a connection choice before connect', (
    tester,
  ) async {
    final hub = _Hub()..devices = [phone(protocol: null)];
    await tester.pumpWidget(_page(hub));
    final connect = find.byKey(const ValueKey('device-connect:$_id'));
    await tester.ensureVisible(connect);
    expect(tester.widget<FilledButton>(connect).onPressed, isNull);
    expect(find.text('Choose connection type · Disconnected'), findsOneWidget);
    await tap(tester, find.byType(DropdownButtonFormField<String>));
    await tap(tester, find.text('CarPlay').last);
    expect(hub.protocolChoices, [(_id, ProjectionProtocol.carPlay)]);
    expect(hub.actions, isEmpty);
    hub.devices = [phone()];
    hub.events.add(null);
    await tester.pump();
    await tap(tester, connect);
    expect(hub.actions, [('connect', _id)]);
    await tester.pumpWidget(const SizedBox());
    await hub.events.close();
  });

  testWidgets(
    'Bluetooth-only choice remains visible and can be changed while disconnected',
    (tester) async {
      final hub = _Hub()
        ..devices = [phone(protocol: null, bluetoothOnly: true)];
      await tester.pumpWidget(_page(hub));
      expect(find.text('Bluetooth · Disconnected'), findsOneWidget);
      expect(find.text('Bluetooth only'), findsOneWidget);
      final connect = find.byKey(const ValueKey('device-connect:$_id'));
      await tester.ensureVisible(connect);
      expect(tester.widget<FilledButton>(connect).onPressed, isNotNull);
      await tap(tester, find.byType(DropdownButtonFormField<String>));
      await tap(tester, find.text('Android Auto').last);
      expect(hub.protocolChoices, [(_id, ProjectionProtocol.androidAuto)]);
      expect(hub.actions, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await hub.events.close();
    },
  );

  testWidgets(
    'pending and failed operations stay visible without duplicate commands',
    (tester) async {
      final pending = Completer<void>();
      final hub = _Hub()
        ..devices = [phone()]
        ..connection = pending.future;
      await tester.pumpWidget(_page(hub));
      final connect = find.byKey(const ValueKey('device-connect:$_id'));
      await tester.ensureVisible(connect);
      await tester.tap(connect);
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(tester.widget<FilledButton>(connect).onPressed, isNull);
      expect(hub.actions, [('connect', _id)]);
      pending.completeError(StateError('Phone rejected the connection'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Phone rejected the connection'),
        findsOneWidget,
      );
      expect(find.byType(LinearProgressIndicator), findsNothing);
      hub.events.addError(StateError('Observer unavailable'));
      await tester.pump();
      expect(
        find.text('Device status is temporarily unavailable.'),
        findsOneWidget,
      );
      expect(tester.widget<FilledButton>(connect).onPressed, isNull);
      expect(tester.takeException(), isNull);
      hub.events.add(null);
      await tester.pump();
      expect(
        find.text('Device status is temporarily unavailable.'),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
      await hub.events.close();
    },
  );

  testWidgets('forget confirms once for the entire device', (tester) async {
    final hub = _Hub()..devices = [phone()];
    await tester.pumpWidget(_page(hub));
    final forget = find.byKey(const ValueKey('device-forget:$_id'));
    await tap(tester, forget);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tap(tester, find.text('Cancel'));
    expect(hub.actions, isEmpty);
    await tap(tester, forget);
    await tap(
      tester,
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Forget device'),
      ),
    );
    expect(hub.actions, [('forget', _id)]);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await hub.events.close();
  });

  testWidgets(
    'adding a phone starts only its chosen protocol and can be cancelled',
    (tester) async {
      final hub = _Hub()..devices = [phone(protocol: null, paired: false)];
      await tester.pumpWidget(_page(hub));
      expect(hub.actions, isEmpty);
      await tap(tester, find.byKey(const ValueKey('add-iphone')));
      expect(hub.pairingChoices, [ProjectionProtocol.carPlay]);
      expect(find.text('Adding CarPlay phone'), findsOneWidget);
      expect(find.textContaining('choose Argo CarPlay'), findsOneWidget);
      await tap(tester, find.byKey(const ValueKey('cancel-device-pairing')));
      expect(hub.actions, [('cancelPairing', '')]);
      await tap(tester, find.byKey(const ValueKey('add-android-phone')));
      expect(hub.pairingChoices, [
        ProjectionProtocol.carPlay,
        ProjectionProtocol.androidAuto,
      ]);
      await tap(tester, find.byKey(const ValueKey('device-pair:$_id')));
      expect(hub.actions.last, ('pair', _id));
      await tester.pumpWidget(const SizedBox());
      await hub.events.close();
    },
  );

  testWidgets('portrait large text keeps wrapped device actions usable', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 426);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final hub = _Hub()
      ..devices = [
        phone(
          name: 'A very long friendly phone name across Bluetooth controllers',
          protocol: null,
        ),
      ];
    await tester.pumpWidget(_page(hub, scale: 2));
    expect(tester.takeException(), isNull);
    final first = tester.element(find.byKey(const ValueKey(_id)));
    await tester.ensureVisible(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    hub.devices = [phone(name: 'A new friendly alias', protocol: null)];
    hub.events.add(null);
    await tester.pump();
    expect(tester.element(find.byKey(const ValueKey(_id))), same(first));
    await tester.ensureVisible(
      find.byKey(const ValueKey('device-forget:$_id')),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(hub.actions, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await hub.events.close();
  });
}

class _Hub implements DeviceConnectionService {
  @override
  List<DeviceHubDevice> devices = [];
  @override
  bool busy = false;
  @override
  String? error;
  @override
  String selectedId = _id;
  @override
  bool autoConnect = true;
  @override
  ProjectionProtocol? pairingProtocol;
  @override
  ConnectivitySnapshot connectivity = const ConnectivitySnapshot(
    available: true,
  );
  @override
  bool carPlayAvailable = true;
  final events = StreamController<void>.broadcast(sync: true);
  final actions = <(String, String)>[];
  final protocolChoices = <(String, ProjectionProtocol?)>[];
  final links = <(String, String)>[];
  final pairingChoices = <ProjectionProtocol>[];
  Future<void>? connection;
  @override
  Stream<void> get changes => events.stream;
  @override
  Future<void> connect(String id) async {
    actions.add(('connect', id));
    await connection;
  }

  @override
  Future<void> disconnect(String id) async => actions.add(('disconnect', id));
  @override
  Future<void> selectProtocol(String id, ProjectionProtocol? protocol) async =>
      protocolChoices.add((id, protocol));
  @override
  Future<void> forget(String id) async => actions.add(('forget', id));
  @override
  Future<void> setAutoConnect(bool value) async {
    autoConnect = value;
    events.add(null);
  }

  @override
  Future<void> beginPairing(ProjectionProtocol protocol) async {
    pairingChoices.add(protocol);
    pairingProtocol = protocol;
    events.add(null);
  }

  @override
  Future<void> cancelPairing() async {
    actions.add(('cancelPairing', ''));
    pairingProtocol = null;
    events.add(null);
  }

  @override
  Future<void> pair(String id) async => actions.add(('pair', id));
  @override
  Future<void> linkDevice(String usbId, String phoneId) async =>
      links.add((usbId, phoneId));
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected device hub operation: ${invocation.memberName}',
  );
}
