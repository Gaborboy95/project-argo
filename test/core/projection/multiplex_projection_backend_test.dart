import 'dart:async';

import 'package:argo/core/projection/multiplex_projection_backend.dart';
import 'package:argo/core/projection/projection_backend.dart';
import 'package:argo/core/projection/projection_models.dart';
import 'package:argo/core/projection/projection_types.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('requires a distinct, known protocol for every adapter', () {
    expect(() => MultiplexProjectionBackend([]), throwsArgumentError);
    final first = _Backend(ProjectionProtocol.androidAuto);
    final second = _Backend(ProjectionProtocol.androidAuto);
    addTearDown(first.close);
    addTearDown(second.close);
    expect(
      () => MultiplexProjectionBackend([first, second]),
      throwsArgumentError,
    );
  });

  test('identical local IDs have distinct opaque control routes', () async {
    final fixture = await _Fixture.start();
    addTearDown(fixture.facade.close);
    final snapshot = fixture.facade.current;
    expect(snapshot.devices.map((d) => d.id).toSet(), hasLength(2));
    expect(snapshot.sessions.map((s) => s.id).toSet(), hasLength(2));
    expect(
      snapshot.sessions.map((s) => s.videoStreams.single.id).toSet(),
      hasLength(2),
    );
    for (final device in snapshot.devices) {
      await fixture.facade.connect(device.id);
    }
    expect(fixture.aa.connections, ['phone']);
    expect(fixture.cp.connections, ['phone']);
    final cp = fixture.session(ProjectionProtocol.carPlay);
    await fixture.facade.setAudioGain(cp.id, cp.audioStreams.single.id, .35);
    expect(fixture.cp.gains, [('session', 'sound', .35)]);
    expect(fixture.aa.gains, isEmpty);
    await expectLater(
      fixture.facade.setAudioGain(
        cp.id,
        fixture.session(ProjectionProtocol.androidAuto).audioStreams.single.id,
        .2,
      ),
      throwsStateError,
    );
  });

  test(
    'incoming video and focus cannot replace the selected protocol',
    () async {
      final fixture = await _Fixture.start();
      addTearDown(fixture.facade.close);
      final owner = fixture.facade.current.activeSessionId;
      fixture.cp.emit(_snapshot(ProjectionProtocol.carPlay, revision: 15));
      expect(fixture.facade.current.activeSessionId, owner);
      final cp = fixture.session(ProjectionProtocol.carPlay);
      expect(cp.videoStreams.single.visible, isFalse);
      expect(cp.videoStreams.single.focused, isFalse);
      expect(cp.videoStreams.single.presentationRevision, 15);
      await expectLater(
        fixture.facade.setVideoVisibility(cp.videoStreams.single.id, true),
        throwsStateError,
      );
      await expectLater(
        fixture.facade.sendTouch(cp.id, _touch(ProjectionTouchPhase.down)),
        throwsStateError,
      );
      expect(fixture.cp.touches, isEmpty);
    },
  );

  test(
    'explicit selection hides old video before activating new owner',
    () async {
      final fixture = await _Fixture.start();
      addTearDown(fixture.facade.close);
      final old = fixture.session(ProjectionProtocol.androidAuto);
      final next = fixture.session(ProjectionProtocol.carPlay);
      await fixture.facade.sendTouch(old.id, _touch(ProjectionTouchPhase.down));
      await fixture.facade.activate(next.id);
      expect(fixture.events, [
        'androidAuto.hide.main',
        'carPlay.activate.session',
      ]);
      expect(fixture.facade.current.activeSessionId, next.id);
      expect(
        fixture
            .session(ProjectionProtocol.androidAuto)
            .videoStreams
            .single
            .visible,
        isFalse,
      );
      await fixture.facade.sendTouch(
        old.id,
        _touch(ProjectionTouchPhase.cancel),
      );
      await fixture.facade.sendTouch(
        next.id,
        _touch(ProjectionTouchPhase.down),
      );
      expect(fixture.aa.touches.map((t) => t.phase), [
        ProjectionTouchPhase.down,
        ProjectionTouchPhase.cancel,
      ]);
      expect(fixture.cp.touches.single.phase, ProjectionTouchPhase.down);
      await expectLater(
        fixture.facade.sendTouch(old.id, _touch(ProjectionTouchPhase.move)),
        throwsStateError,
      );
    },
  );

  test('host hide survives late focus and main-stream replacement', () async {
    final fixture = await _Fixture.start();
    addTearDown(fixture.facade.close);
    final original = fixture.session(ProjectionProtocol.androidAuto);
    await fixture.facade.setVideoVisibility(
      original.videoStreams.single.id,
      false,
    );
    fixture.aa.emit(
      _snapshot(
        ProjectionProtocol.androidAuto,
        videoId: 'replacement',
        revision: 10,
      ),
    );
    final hidden = fixture.session(ProjectionProtocol.androidAuto);
    expect(fixture.facade.current.activeSessionId, original.id);
    expect(hidden.videoStreams.single.visible, isFalse);
    await expectLater(
      fixture.facade.sendTouch(hidden.id, _touch(ProjectionTouchPhase.down)),
      throwsStateError,
    );
    await fixture.facade.activate(hidden.id);
    expect(
      fixture.facade.current.activeSession!.videoStreams.single.visible,
      isTrue,
    );
  });

  test(
    'failed selection cannot grant another owner or undo local hide',
    () async {
      final fixture = await _Fixture.start();
      addTearDown(fixture.facade.close);
      final original = fixture.facade.current.activeSessionId;
      fixture.cp.activationError = StateError('Disconnected');
      await expectLater(
        fixture.facade.activate(fixture.session(ProjectionProtocol.carPlay).id),
        throwsStateError,
      );
      expect(fixture.facade.current.activeSessionId, original);
      expect(
        fixture.facade.current.activeSession!.videoStreams.single.visible,
        isFalse,
      );
      // The serialized command queue must remain usable after the error.
      await fixture.facade.activate(original!);
      expect(
        fixture.facade.current.activeSession!.videoStreams.single.visible,
        isTrue,
      );
    },
  );

  test(
    'adapter failure does not steal selection or disable another adapter',
    () async {
      final fixture = await _Fixture.start();
      addTearDown(fixture.facade.close);
      fixture.aa.fail();
      expect(fixture.facade.current.backendAvailable, isTrue);
      expect(fixture.facade.current.activeSessionId, isNull);
      expect(fixture.facade.current.sessions, hasLength(1));
      final cp = fixture.session(ProjectionProtocol.carPlay);
      await fixture.facade.activate(cp.id);
      expect(fixture.facade.current.activeSessionId, cp.id);
    },
  );

  test(
    'reconnected raw IDs cannot receive commands for a retired session',
    () async {
      final fixture = await _Fixture.start();
      addTearDown(fixture.facade.close);
      final old = fixture.session(ProjectionProtocol.androidAuto);
      fixture.aa.emit(ProjectionSnapshot(backendAvailable: true));
      fixture.aa.emit(_snapshot(ProjectionProtocol.androidAuto));
      final replacement = fixture.session(ProjectionProtocol.androidAuto);
      expect(replacement.id, isNot(old.id));
      expect(
        replacement.videoStreams.single.id,
        isNot(old.videoStreams.single.id),
      );
      await expectLater(
        fixture.facade.sendTouch(old.id, _touch(ProjectionTouchPhase.cancel)),
        throwsStateError,
      );
      expect(fixture.aa.touches, isEmpty);
    },
  );

  test(
    'session replacement during activation does not retarget request',
    () async {
      final fixture = await _Fixture.start();
      addTearDown(fixture.facade.close);
      final original = fixture.session(ProjectionProtocol.carPlay);
      final entered = Completer<void>();
      final release = Completer<void>();
      fixture.cp.activation = () async {
        entered.complete();
        await release.future;
      };
      final pending = fixture.facade.activate(original.id);
      final rejected = expectLater(pending, throwsStateError);
      await entered.future;
      fixture.cp.emit(ProjectionSnapshot(backendAvailable: true));
      fixture.cp.emit(_snapshot(ProjectionProtocol.carPlay));
      release.complete();
      await rejected;
      expect(
        fixture.facade.current.activeSession!.device.protocol,
        ProjectionProtocol.androidAuto,
      );
    },
  );

  test('startup failure is isolated; start and close are idempotent', () async {
    final aa = _Backend(ProjectionProtocol.androidAuto);
    final cp = _Backend(ProjectionProtocol.carPlay)
      ..startupError = StateError('Unavailable');
    final facade = MultiplexProjectionBackend([aa, cp]);
    await Future.wait([facade.start(), facade.start()]);
    expect(facade.current.backendAvailable, isTrue);
    expect(
      facade.current.sessions.single.device.protocol,
      ProjectionProtocol.androidAuto,
    );
    expect(aa.starts, 1);
    expect(cp.starts, 1);
    await Future.wait([facade.close(), facade.close()]);
    expect(aa.closes, 1);
    expect(cp.closed, isTrue);
  });

  test(
    'shutdown releases the healthy adapter after another close fails',
    () async {
      final fixture = await _Fixture.start();
      fixture.aa.closeError = StateError('Cleanup failed');
      await expectLater(fixture.facade.close(), throwsStateError);
      expect(fixture.cp.closed, isTrue);
      expect(fixture.aa.closed, isTrue);
    },
  );
}

ProjectionTouch _touch(ProjectionTouchPhase phase) =>
    ProjectionTouch(pointerId: 7, phase: phase, x: .25, y: .75);

ProjectionSnapshot _snapshot(
  ProjectionProtocol protocol, {
  String videoId = 'main',
  int revision = 0,
}) {
  final device = ProjectionDevice(
    id: 'phone',
    displayName: 'Fixture phone',
    protocol: protocol,
    transport: ProjectionTransport.usb,
  );
  return ProjectionSnapshot(
    backendAvailable: true,
    devices: [device],
    activeSessionId: 'session',
    sessions: [
      ProjectionSession(
        id: 'session',
        device: device,
        state: ProjectionSessionState.streaming,
        videoStreams: [
          ProjectionVideoStream(
            id: videoId,
            sessionId: 'session',
            role: ProjectionVideoRole.main,
            codec: ProjectionVideoCodec.h264,
            width: 1280,
            height: 720,
            framesPerSecond: 30,
            presentationRevision: revision,
          ),
        ],
        audioStreams: const [
          ProjectionAudioStream(
            id: 'sound',
            sessionId: 'session',
            role: ProjectionAudioRole.media,
            active: true,
            hasFocus: true,
          ),
        ],
      ),
    ],
  );
}

final class _Fixture {
  _Fixture(this.aa, this.cp, this.facade, this.events);
  static Future<_Fixture> start() async {
    final events = <String>[];
    final aa = _Backend(ProjectionProtocol.androidAuto, events: events);
    final cp = _Backend(ProjectionProtocol.carPlay, events: events);
    final facade = MultiplexProjectionBackend([aa, cp]);
    await facade.start();
    return _Fixture(aa, cp, facade, events);
  }

  final _Backend aa, cp;
  final MultiplexProjectionBackend facade;
  final List<String> events;
  ProjectionSession session(ProjectionProtocol protocol) =>
      facade.current.sessions.singleWhere((s) => s.device.protocol == protocol);
}

final class _Backend implements ProjectionBackend {
  _Backend(this.protocol, {List<String>? events})
    : events = events ?? [],
      current = _snapshot(protocol);
  @override
  final ProjectionProtocol protocol;
  @override
  ProjectionSnapshot current;
  final List<String> events;
  final _changes = StreamController<ProjectionSnapshot>.broadcast(sync: true);
  @override
  Stream<ProjectionSnapshot> get changes => _changes.stream;
  final connections = <String>[];
  final gains = <(String, String, double)>[];
  final touches = <ProjectionTouch>[];
  int starts = 0, closes = 0;
  bool closed = false;
  Object? startupError, activationError, closeError;
  Future<void> Function()? activation;
  void emit(ProjectionSnapshot snapshot) {
    current = snapshot;
    _changes.add(snapshot);
  }

  void fail() => _changes.addError(StateError('Unavailable'));
  @override
  Future<void> start() async {
    starts++;
    if (startupError != null) throw startupError!;
  }

  @override
  Future<void> connect(String deviceId) async => connections.add(deviceId);
  @override
  Future<void> disconnect(String sessionId) async {}
  @override
  Future<void> activate(String sessionId) async {
    events.add('${protocol.name}.activate.$sessionId');
    if (activationError != null) throw activationError!;
    await activation?.call();
  }

  @override
  Future<void> sendTouch(String sessionId, ProjectionTouch touch) async =>
      touches.add(touch);
  @override
  Future<void> sendButton(
    String sessionId,
    ProjectionInputButton button, {
    required bool pressed,
  }) async {}
  @override
  Future<void> sendRotary(String sessionId, int detents) async {}
  @override
  Future<void> setVideoVisibility(String streamId, bool visible) async =>
      events.add('${protocol.name}.${visible ? 'show' : 'hide'}.$streamId');
  @override
  Future<void> setAudioGain(
    String sessionId,
    String streamId,
    double gain,
  ) async => gains.add((sessionId, streamId, gain));
  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    closes++;
    await _changes.close();
    if (closeError != null) throw closeError!;
  }
}
