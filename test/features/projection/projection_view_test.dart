import 'dart:async';

import 'package:argo/core/projection/in_memory_projection_backend.dart';
import 'package:argo/core/projection/projection_models.dart';
import 'package:argo/core/projection/projection_service.dart';
import 'package:argo/core/projection/projection_types.dart';
import 'package:argo/features/projection/projection_view.dart';
import 'package:argo/features/projection/projection_input_scope.dart';
import 'package:argo/app/argo_environment.dart';
import 'package:argo/app/navigation/app_module.dart';
import 'package:argo/app/navigation/app_module_registry.dart';
import 'package:argo/app/shell/app_shell.dart';
import 'package:argo/core/services/service_registry.dart';
import 'package:argo/core/settings/app_setting_keys.dart';
import 'package:argo/core/settings/settings_service.dart';
import 'package:argo/core/settings/settings_store.dart';
import 'package:argo/features/media/media_page.dart';
import 'package:argo/core/projection/projection_touch_mapper.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'IHS emits a platform-view layer with matching ID and maps input once',
    (tester) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        (call) async {
          calls.add(call);
          return call.method == 'create' ? (call.arguments as Map)['id'] : null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform_views,
          null,
        ),
      );
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = InMemoryProjectionBackend(initial: _liveSnapshot());
      final service = _DirectProjectionService(backend);
      final stream = ProjectionVideoStream(
        id: 'main',
        sessionId: 'session',
        role: ProjectionVideoRole.main,
        codec: ProjectionVideoCodec.h264,
        width: 1280,
        height: 720,
        framesPerSecond: 30,
      );
      Widget page(double width) => MaterialApp(
        home: Center(
          child: SizedBox(
            width: width,
            height: width * 720 / 1280,
            child: ProjectionView(
              service: service,
              sessionId: 'session',
              stream: stream,
            ),
          ),
        ),
      );
      await tester.pumpWidget(page(320));
      await tester.pumpAndSettle();
      final create =
          calls.singleWhere((call) => call.method == 'create').arguments as Map;
      final id = create['id'];
      expect(create['viewType'], ProjectionView.viewType);
      expect(create['width'], 320.0); // Logical size, despite DPR 2.
      expect(create['height'], 180.0);
      expect(
        const StandardMessageCodec().decodeMessage(
          ByteData.sublistView(create['params'] as Uint8List),
        ),
        {'streamId': 'main'},
      );
      expect(
        tester.layers.whereType<PlatformViewLayer>().map(
          (layer) => layer.viewId,
        ),
        [id],
      );
      expect(tester.layers.whereType<TextureLayer>(), isEmpty);

      await tester.pumpWidget(page(300));
      await tester.pumpAndSettle();
      expect(calls.where((call) => call.method == 'create'), hasLength(1));
      final resize =
          calls.lastWhere((call) => call.method == 'resize').arguments as Map;
      expect(resize, {'id': id, 'width': 300.0, 'height': 168.75});

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(ProjectionView)),
      );
      await gesture.up();
      await tester.pump();

      expect(backend.touches.map((touch) => touch.phase), [
        ProjectionTouchPhase.down,
        ProjectionTouchPhase.up,
      ]);
      expect(backend.touches.first.x, closeTo(0.5, 0.01));
      expect(calls.where((call) => call.method == 'touch'), isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(calls.where((call) => call.method == 'dispose'), hasLength(1));
      await backend.close();
    },
  );

  testWidgets('accepted pointers end outside content and later gestures work', (
    tester,
  ) async {
    final backend = InMemoryProjectionBackend(initial: _liveSnapshot());
    final service = _DirectProjectionService(backend);
    await tester.pumpWidget(_gesturePage(service));
    final outside = await tester.startGesture(
      const Offset(210, 170),
      pointer: 1,
    );
    await outside.up();
    expect(backend.touches, isEmpty);
    final inside = await tester.startGesture(
      const Offset(400, 300),
      pointer: 2,
    );
    await inside.moveTo(const Offset(10, 10));
    await inside.up();
    await tester.pump();
    expect(backend.touches.map((t) => t.phase), [
      ProjectionTouchPhase.down,
      ProjectionTouchPhase.up,
    ]);
    expect(backend.touches.last.x, backend.touches.first.x);
    final next = await tester.startGesture(const Offset(400, 300), pointer: 3);
    await next.moveTo(const Offset(10, 10));
    await next.cancel();
    await tester.pump();
    final again = await tester.startGesture(const Offset(400, 300), pointer: 4);
    await again.up();
    await tester.pump();
    expect(backend.touches.map((t) => t.phase), [
      ProjectionTouchPhase.down,
      ProjectionTouchPhase.up,
      ProjectionTouchPhase.down,
      ProjectionTouchPhase.cancel,
      ProjectionTouchPhase.down,
      ProjectionTouchPhase.up,
    ]);
    // Hover/secondary mouse presses do not create remote touches.
    final mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await mouse.addPointer(location: const Offset(400, 300));
    await mouse.down(const Offset(400, 300));
    await mouse.up();
    await tester.pump();
    expect(backend.touches, hasLength(6));
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox());
    await backend.close();
  });

  testWidgets(
    'ownership loss cancels once and terminal events bypass pending moves',
    (tester) async {
      final backend = InMemoryProjectionBackend(initial: _liveSnapshot());
      final service = _DirectProjectionService(backend)
        ..hold = Completer<void>();
      await tester.pumpWidget(_gesturePage(service));
      final gesture = await tester.startGesture(
        const Offset(400, 300),
        pointer: 5,
      );
      for (var i = 0; i < 12; i++) {
        await gesture.moveTo(Offset(410 + i.toDouble(), 300));
      }
      await tester.pumpWidget(_gesturePage(service, active: false));
      await gesture.up();
      // Other loss notifications must not emit another ACTION_CANCEL.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      service.hold!.complete();
      await tester.pump();
      expect(backend.touches.map((t) => t.phase), [
        ProjectionTouchPhase.down,
        ProjectionTouchPhase.cancel,
      ]);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(_gesturePage(service));
      final next = await tester.startGesture(
        const Offset(400, 300),
        pointer: 6,
      );
      await next.up();
      await tester.pump();
      expect(backend.touches.map((t) => t.phase), [
        ProjectionTouchPhase.down,
        ProjectionTouchPhase.cancel,
        ProjectionTouchPhase.down,
        ProjectionTouchPhase.up,
      ]);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(backend.touches, hasLength(4));
      await backend.close();
    },
  );

  testWidgets(
    'expanded render and touch share a fitted rectangle at non-unit DPR',
    (tester) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(1600, 1200);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        (call) async {
          calls.add(call);
          return call.method == 'create' ? (call.arguments as Map)['id'] : null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform_views,
          null,
        ),
      );
      final stream = ProjectionVideoStream(
        id: 'main',
        sessionId: 'session',
        role: ProjectionVideoRole.main,
        codec: ProjectionVideoCodec.h264,
        width: 1280,
        height: 720,
        framesPerSecond: 30,
        contentInsets: const ProjectionInsets(left: 80, right: 80),
        safeInsets: const ProjectionInsets(left: 40, top: 20),
      );
      final backend = InMemoryProjectionBackend(
        initial: _liveSnapshot(stream: stream),
      );
      final service = _DirectProjectionService(backend);
      late SettingsService settings;
      await tester.runAsync(() async {
        settings = await SettingsService.load(
          schema: AppSettingKeys.createSchema(),
          store: _GeometryStore(),
        );
      });
      final modules = AppModuleRegistry()
        ..register(
          AppModule(
            id: 'media',
            label: 'Media',
            icon: Icons.music_note,
            builder: (_, _) => MediaPage(projection: service),
          ),
        );
      await tester.pumpWidget(
        MaterialApp(
          home: AppShell(
            environment: ArgoEnvironment(
              services: ServiceRegistry()..register(settings),
              moduleRegistry: modules,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('ARGO'), findsOneWidget);
      await tester.tap(find.text('Compare size'));
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'create'), hasLength(1));
      expect(find.text('ARGO'), findsNothing);
      final fitted = const ProjectionViewGeometry(
        width: 800,
        height: 600,
        devicePixelRatio: 2,
        preferPhysicalPixels: true,
      ).fit(1280, 720)!;
      expect(fitted.isOneToOne, isTrue);
      expect(
        tester.getRect(find.byType(PlatformViewSurface)),
        Rect.fromLTWH(fitted.left, fitted.top, fitted.width, fitted.height),
      );
      expect(fitted.physicalWidth, 1280);
      expect(fitted.physicalHeight, 720);
      expect(find.textContaining('1:1 physical pixels'), findsOneWidget);
      final pointer = await tester.startGesture(
        Offset(fitted.left + (80 + 1120 * 0.25) / 2, fitted.top + 360 / 2),
      );
      await pointer.up();
      await tester.pump();
      expect(backend.touches.first.x, closeTo(0.25, 0.0001));
      expect(backend.touches.first.y, closeTo(0.5, 0.0001));
      final bars = await tester.startGesture(const Offset(790, 590));
      await bars.up();
      await tester.pump();
      expect(backend.touches, hasLength(2));
      tester.view.physicalSize = const Size(1000, 700);
      await tester.pumpAndSettle();
      expect(find.textContaining('1:1 physical pixels'), findsNothing);
      expect(find.textContaining('scaled to fit'), findsOneWidget);
      expect(
        tester.getSize(find.byType(PlatformViewSurface)),
        const Size(500, 281.25),
      );
      await tester.tap(find.text('Back to Argo'));
      await tester.pumpAndSettle();
      expect(find.text('Compare size'), findsOneWidget);
      expect(calls.where((c) => c.method == 'create'), hasLength(1));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await backend.close();
      await tester.runAsync(settings.close);
    },
  );

  testWidgets(
    'IHS cleans up delayed creation and reports unavailable channels',
    (tester) async {
      final pending = Completer<Object?>();
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        (call) async {
          calls.add(call);
          return call.method == 'create' ? pending.future : null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform_views,
          null,
        ),
      );
      await tester.pumpWidget(
        const MaterialApp(home: ProjectionView.rendererTest()),
      );
      await tester.pump();
      final id = (calls.single.arguments as Map)['id'];
      expect(tester.layers.whereType<PlatformViewLayer>(), isEmpty);
      await tester.pumpWidget(const SizedBox());
      expect(calls.where((call) => call.method == 'dispose'), isEmpty);
      pending.complete(id);
      await tester.pumpAndSettle();
      expect(calls.where((call) => call.method == 'dispose'), hasLength(1));
      expect((calls.last.arguments as Map)['id'], id);
      expect(tester.layers.whereType<PlatformViewLayer>(), isEmpty);
      expect(tester.takeException(), isNull);

      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        (_) async => throw MissingPluginException('Not an IHS runner'),
      );
      await tester.pumpWidget(
        const MaterialApp(home: ProjectionView.rendererTest()),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Native projection surface unavailable'),
        findsOneWidget,
      );
      expect(tester.layers.whereType<PlatformViewLayer>(), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}

final class _DirectProjectionService implements ProjectionService {
  _DirectProjectionService(this.backend);
  final InMemoryProjectionBackend backend;
  Completer<void>? hold;
  @override
  ProjectionSnapshot get current => backend.current;
  @override
  Stream<ProjectionSnapshot> get changes => backend.changes;
  @override
  Future<void> activate(String sessionId) => backend.activate(sessionId);
  @override
  Future<void> close() => backend.close();
  @override
  Future<void> connect(String deviceId) => backend.connect(deviceId);
  @override
  Future<void> disconnect(String sessionId) => backend.disconnect(sessionId);
  @override
  Future<void> sendButton(
    String sessionId,
    ProjectionInputButton button, {
    required bool pressed,
  }) => backend.sendButton(sessionId, button, pressed: pressed);
  @override
  Future<void> sendRotary(String sessionId, int detents) =>
      backend.sendRotary(sessionId, detents);
  @override
  Future<void> sendTouch(String sessionId, ProjectionTouch touch) async {
    await backend.sendTouch(sessionId, touch);
    if (touch.phase == ProjectionTouchPhase.down) await hold?.future;
  }

  @override
  Future<void> setVideoVisibility(String streamId, bool visible) =>
      backend.setVideoVisibility(streamId, visible);
}

ProjectionVideoStream _mainStream() => ProjectionVideoStream(
  id: 'main',
  sessionId: 'session',
  role: ProjectionVideoRole.main,
  codec: ProjectionVideoCodec.h264,
  width: 1280,
  height: 720,
  framesPerSecond: 30,
);
ProjectionSnapshot _liveSnapshot({ProjectionVideoStream? stream}) =>
    ProjectionSnapshot(
      backendAvailable: true,
      activeSessionId: 'session',
      sessions: [
        ProjectionSession(
          id: 'session',
          device: const ProjectionDevice(
            id: 'phone',
            displayName: 'Phone',
            protocol: ProjectionProtocol.androidAuto,
            transport: ProjectionTransport.usb,
          ),
          state: ProjectionSessionState.streaming,
          videoStreams: [stream ?? _mainStream()],
        ),
      ],
    );
Widget _gesturePage(ProjectionService service, {bool active = true}) =>
    MaterialApp(
      home: Center(
        child: SizedBox(
          width: 400,
          height: 300,
          child: ProjectionInputScope(
            active: active,
            child: ProjectionView(
              service: service,
              sessionId: 'session',
              stream: _mainStream(),
              nativeViewBuilder: (_, _) =>
                  const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ),
    );

class _GeometryStore implements SettingsStore {
  SettingsDocument document = SettingsDocument();
  @override
  Future<SettingsDocument> read() async => document;
  @override
  Future<void> write(SettingsDocument value) async {
    document = value;
  }
}
