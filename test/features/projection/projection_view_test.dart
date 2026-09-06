import 'dart:async';

import 'package:argo/core/projection/in_memory_projection_backend.dart';
import 'package:argo/core/projection/projection_models.dart';
import 'package:argo/core/projection/projection_service.dart';
import 'package:argo/core/projection/projection_types.dart';
import 'package:argo/features/projection/projection_view.dart';
import 'package:flutter/material.dart';
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
      final backend = InMemoryProjectionBackend();
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
  Future<void> sendTouch(String sessionId, ProjectionTouch touch) =>
      backend.sendTouch(sessionId, touch);
  @override
  Future<void> setVideoVisibility(String streamId, bool visible) =>
      backend.setVideoVisibility(streamId, visible);
}
