import 'dart:convert';

import 'package:argo/core/media/media_session_service.dart';
import 'package:argo/core/projection/projection_service.dart';
import 'package:argo/core/projection/projection_backend.dart';
import 'package:argo/core/projection/multiplex_projection_backend.dart';
import 'package:argo/core/projection/projection_models.dart';
import 'package:argo/integrations/projection/projection_media_source.dart';
import 'package:argo/integrations/bluetooth/bluetooth_media_source.dart';

import 'dart:async';
import 'dart:io';

import 'package:argo/core/diagnostics/diagnostics_service.dart';
import 'package:argo/core/projection/disabled_projection_backend.dart';
import 'package:argo/core/projection/projection_preferences.dart';
import 'package:argo/core/projection/projection_types.dart';
import 'package:argo/integrations/projection/android_auto_projection_backend.dart';
import 'package:argo/core/projection/projection_configuration.dart';
import 'package:argo/integrations/projection/projection_endpoints.dart';
import 'package:argo/integrations/projection/projection_backend_selection.dart';
import 'package:argo/integrations/projection/projection_ipc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final preferences = ProjectionPreferences(
    width: 1280,
    height: 720,
    dpi: 160,
    framesPerSecond: 30,
    driverSide: ProjectionDriverSide.left,
    safeInsets: const ProjectionInsets(),
  );

  test(
    'IPC v8 connectivity is independent of AA readiness and closes truthfully',
    () async {
      final transport = _FakeTransport();
      final backend = AndroidAutoProjectionBackend(
        socketPath: '/tmp/test.sock',
        preferences: preferences,
        diagnostics: DiagnosticsService(),
        transportFactory: (_) async => transport,
      );
      await backend.start();
      transport.emit(const ProjectionIpcMessage(ProjectionIpcKind.hello));
      final hex = File('test/fixtures/projection/ipc_v8_connectivity.hex')
          .readAsStringSync()
          .trim();
      transport.emit(
        ProjectionIpcDecoder().add([
          for (var i = 0; i < hex.length; i += 2)
            int.parse(hex.substring(i, i + 2), radix: 16),
        ]).single,
      );
      expect(backend.connectivity.available, isTrue);
      expect(backend.connectivity.enabled, isFalse);
      expect(backend.connectivity.prompt!.device, 'hci0/02:00:00:00:00:01');
      expect(transport.sent.length, 2);
      expect(
        jsonDecode(utf8.decode(transport.sent.last.payload))['action'],
        'projectionEnabled',
      ); // No automatic pairing confirmation.
      await backend.connectivityCommand('confirm', prompt: 42, accept: false);
      expect(jsonDecode(utf8.decode(transport.sent.last.payload)), {
        'action': 'confirm',
        'target': '',
        'accept': false,
        'prompt': 42,
      });
      await transport.crash();
      expect(backend.connectivity.available, isFalse);
      expect(backend.connectivity.prompt, isNull);
      await backend.close();
    },
  );

  test('shared metadata snapshot is current, deduplicated and scoped to its originating session', () async {
    final transport = _FakeTransport();
    final backend = AndroidAutoProjectionBackend(
      socketPath: '/tmp/test.sock',
      preferences: preferences,
      diagnostics: DiagnosticsService(),
      transportFactory: (_) async => transport,
    );
    await backend.start();
    transport.emit(const ProjectionIpcMessage(ProjectionIpcKind.hello));
    transport.emit(_capabilities());
    transport.emit(
      ProjectionIpcMessage(
        ProjectionIpcKind.device,
        (ProjectionIpcWriter()
              ..string('device')
              ..string('Android phone')
              ..uint8(0)
              ..uint8(0))
            .takeBytes(),
      ),
    );
    void session(String id) => transport.emit(
      ProjectionIpcMessage(
        ProjectionIpcKind.session,
        (ProjectionIpcWriter()
              ..string(id)
              ..string('device')
              ..uint8(1)
              ..string('')
              ..uint32(0))
            .takeBytes(),
      ),
    );
    session('aa-wired:device');
    final hex = File('test/fixtures/projection/ipc_v8_metadata.hex')
        .readAsStringSync()
        .trim();
    final packet = ProjectionIpcDecoder().add([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]).single;
    transport.emit(
      packet,
    ); // already connected before the application media adapter attaches
    final media = CachedMediaSessionService();
    final source = ProjectionMediaSource(_BackendProjection(backend), media);
    expect(media.current.activeSource!.details.title, 'Song');
    expect(media.current.activeSource!.details.positionMs, 12000);
    expect(media.current.activeSource!.details.durationMs, isNull);
    expect(
      backend.current.sessions.single.metadata!.phone.batteryPercent,
      isNull,
    );
    expect(
      backend.current.activeSessionId,
      isNull,
    ); // media selection is independent
    var changes = 0;
    final subscription = media.changes.listen((_) => changes++);
    transport.emit(packet);
    expect(changes, 0);
    final returnHex = File('test/fixtures/projection/ipc_v8_host_return.hex')
        .readAsStringSync()
        .trim();
    transport.emit(
      ProjectionIpcDecoder().add([
        for (var i = 0; i < returnHex.length; i += 2)
          int.parse(returnHex.substring(i, i + 2), radix: 16),
      ]).single,
    );
    expect(backend.current.sessions.single.hostReturnRevision, 1);
    expect(
      backend.current.sessions.single.state,
      ProjectionSessionState.suspended,
    );
    expect(media.current.activeSource!.details.title, 'Song');
    expect(changes, 0);
    transport.emit(
      ProjectionIpcMessage(
        ProjectionIpcKind.sessionRemoved,
        (ProjectionIpcWriter()..string('aa-wired:device')).takeBytes(),
      ),
    );
    expect(media.current.activeSource, isNull);
    session('replacement');
    transport.emit(
      packet,
    ); // late update from old session cannot populate replacement
    expect(media.current.sources.single.details.title, isNull);
    expect(media.current.sources.single.commands, isEmpty);
    expect(backend.current.sessions.single.metadata, isNull);
    expect(changes, 2);
    await subscription.cancel();
    await source.close();
    await media.close();
    await backend.close();
  });

  test('qualified AA sources control hidden media through their own input transport', () async {
    final transport = _FakeTransport();
    final backend = AndroidAutoProjectionBackend(
      socketPath: '/tmp/test.sock',
      preferences: preferences,
      diagnostics: DiagnosticsService(),
      transportFactory: (_) async => transport,
    );
    final multiplex = MultiplexProjectionBackend([backend, _AbsentCarPlay()]);
    await multiplex.start();
    transport.emit(const ProjectionIpcMessage(ProjectionIpcKind.hello));
    transport.emit(_capabilities());
    _announcePhone(transport, state: ProjectionSessionState.suspended);
    final media = CachedMediaSessionService();
    final bluetooth = BluetoothMediaSource(backend, media);
    final provider = ProjectionMediaSource(
      _BackendProjection(multiplex),
      media,
      connectivity: backend,
    );
    expect(media.current.sources.single.commands, isEmpty);
    final fixture = _fixture('ipc_v8_metadata.hex');
    transport.emit(
      ProjectionIpcMessage(fixture.kind, [...fixture.payload]..last = 31),
    );
    final source = media.current.activeSource!;
    expect(source.sessionId, isNot('aa-wired:device'));
    expect(source.id, 'projection:${source.sessionId}:media');
    expect(source.commands, ['previous', 'play', 'pause', 'next', 'playPause']);
    expect(multiplex.current.sessions.single.videoStreams, isEmpty);
    transport.sent.clear();
    for (final entry in [
      ('previous', 9),
      ('play', 13),
      ('pause', 14),
      ('next', 8),
      ('playPause', 7),
    ]) {
      await media.command(source.id, entry.$1);
      final packets = transport.sent.toList();
      expect(packets, hasLength(2));
      for (var i = 0; i < packets.length; i++) {
        expect(packets[i].kind, ProjectionIpcKind.button);
        final payload = ProjectionIpcReader(packets[i].payload);
        expect(payload.string(), 'aa-wired:device');
        expect(payload.uint8(), entry.$2);
        expect(payload.uint8(), i == 0 ? 1 : 0);
        expect(payload.isDone, isTrue);
      }
      transport.sent.clear();
    }
    expect(backend.current.activeSessionId, isNull);
    expect(
      backend.current.sessions.single.state,
      ProjectionSessionState.suspended,
    );
    transport.emit(_mediaMetadata(revision: 4, commands: 0));
    expect(media.current.sources.single.commands, isEmpty);
    await expectLater(
      media.command(source.id, 'playPause'),
      throwsUnsupportedError,
    );
    expect(transport.sent, isEmpty);
    transport.emit(
      ProjectionIpcMessage(
        ProjectionIpcKind.sessionRemoved,
        (ProjectionIpcWriter()..string('aa-wired:device')).takeBytes(),
      ),
    );
    _announcePhone(transport, state: ProjectionSessionState.suspended);
    transport.emit(_mediaMetadata(revision: 5, commands: 31));
    expect(media.current.sources.single.id, isNot(source.id));
    await expectLater(media.command(source.id, 'playPause'), throwsStateError);
    expect(transport.sent, isEmpty);
    await provider.close();
    await bluetooth.close();
    await media.close();
    await multiplex.close();
  });

  test(
    'input capability metadata exposes an idle player before any track arrives',
    () async {
      final transport = _FakeTransport();
      final backend = AndroidAutoProjectionBackend(
        socketPath: '/tmp/test.sock',
        preferences: preferences,
        diagnostics: DiagnosticsService(),
        transportFactory: (_) async => transport,
      );
      await backend.start();
      transport.emit(const ProjectionIpcMessage(ProjectionIpcKind.hello));
      transport.emit(_capabilities());
      _announcePhone(transport);
      final media = CachedMediaSessionService();
      final provider = ProjectionMediaSource(
        _BackendProjection(backend),
        media,
      );
      transport.emit(_mediaMetadata(received: false));
      final source = media.current.activeSource!;
      expect(source.details.title, isNull);
      expect(source.commands, contains('playPause'));
      expect(backend.current.sessions.single.metadata!.media, isNull);
      transport.sent.clear();
      await media.command(source.id, 'playPause');
      expect(transport.sent.map((m) => m.kind), [
        ProjectionIpcKind.button,
        ProjectionIpcKind.button,
      ]);
      await provider.close();
      await media.close();
      await backend.close();
    },
  );

  test(
    'v8 media fields preserve reported modes and a signed unscaled rating',
    () async {
      final transport = _FakeTransport();
      final backend = AndroidAutoProjectionBackend(
        socketPath: '/tmp/test.sock',
        preferences: preferences,
        diagnostics: DiagnosticsService(),
        transportFactory: (_) async => transport,
      );
      await backend.start();
      transport.emit(const ProjectionIpcMessage(ProjectionIpcKind.hello));
      transport.emit(_capabilities());
      _announcePhone(transport);
      transport.emit(_mediaMetadata());
      final metadata = backend.current.sessions.single.metadata!;
      final details = metadata.media!;
      expect(
        (details.title, details.application, details.playlist),
        ('Track', 'Player', 'Roadtrip'),
      );
      expect((details.positionMs, details.durationMs), (42000, 123000));
      expect(
        (details.shuffle, details.repeat, details.repeatOne),
        (true, false, true),
      );
      expect(details.rating, -1);
      expect(metadata.mediaCommands, [
        'previous',
        'play',
        'pause',
        'next',
        'playPause',
      ]);
      await backend.close();
    },
  );

  test('malformed optional v8 extensions retain good media and keep the receiver available', () async {
    for (final malformed in ['shuffle', 'rating', 'commands', 'truncated']) {
      final transport = _FakeTransport();
      final backend = AndroidAutoProjectionBackend(
        socketPath: '/tmp/test.sock',
        preferences: preferences,
        diagnostics: DiagnosticsService(),
        transportFactory: (_) async => transport,
      );
      await backend.start();
      transport.emit(const ProjectionIpcMessage(ProjectionIpcKind.hello));
      transport.emit(_capabilities());
      _announcePhone(transport);
      transport.emit(_mediaMetadata());
      final good = backend.current.sessions.single.metadata;
      transport.emit(_mediaMetadata(revision: 4, malformed: malformed));
      expect(backend.current.backendAvailable, isTrue, reason: malformed);
      expect(
        backend.current.sessions.single.metadata,
        same(good),
        reason: malformed,
      );
      await backend.close();
    }
  });

  test('disabled backend is safe and default', () async {
    final backend = await selectProjectionBackend(
      environment: const {},
      preferences: preferences,
      diagnostics: DiagnosticsService(),
      isLinux: false,
    );
    expect(backend, isA<DisabledProjectionBackend>());
  });

  test('Android Auto is rejected off Linux', () async {
    await expectLater(
      selectProjectionBackend(
        environment: const {'ARGO_PROJECTION_BACKEND': 'android-auto'},
        preferences: preferences,
        diagnostics: DiagnosticsService(),
        isLinux: false,
      ),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('credential-free client hello ignores inherited identity and resolves endpoints', () async {
    for (final inherited in [false, true]) {
      final transport = _FakeTransport();
      final backend = await selectProjectionBackend(
        environment: {
          'ARGO_PROJECTION_BACKEND': 'android-auto',
          'XDG_RUNTIME_DIR': '/run/user/1000',
          if (inherited) 'ARGO_ANDROID_AUTO_KEY_FILE': '/private/must-not-open',
          if (inherited)
            'ARGO_ANDROID_AUTO_CERT_FILE': '/private/must-not-open',
        },
        preferences: preferences,
        diagnostics: DiagnosticsService(),
        isLinux: true,
        transportFactory: (path) async {
          expect(path, '/run/user/1000/argo/projection.sock');
          return transport;
        },
      );
      await backend.start();
      expect(transport.sent.single.kind, ProjectionIpcKind.hello);
      expect(transport.sent.single.payload, isEmpty);
      transport.emit(const ProjectionIpcMessage(ProjectionIpcKind.hello));
      transport.emit(_capabilities());
      expect(backend.current.backendAvailable, isTrue);
      final config = backend as ProjectionConfigurationBackend;
      expect(config.configuration.capabilities!.audio.first.rate, 48000);
      expect(transport.sent.last.kind, ProjectionIpcKind.configure);
      expect(
        transport.sent.last.payload.length,
        28,
      ); // revision + display, no paths
      transport.emit(
        ProjectionIpcMessage(
          ProjectionIpcKind.error,
          (ProjectionIpcWriter()..string('Configure identity on the daemon'))
              .takeBytes(),
        ),
      );
      transport.emit(
        ProjectionIpcMessage(
          ProjectionIpcKind.deviceRemoved,
          (ProjectionIpcWriter()..string('unplugged')).takeBytes(),
        ),
      );
      expect(
        backend.current.failureMessage,
        contains('identity on the daemon'),
      );
      await backend.close();
    }
    expect(
      projectionEndpoint({}, 'ARGO_PROJECTION_SOCKET', 'projection.sock'),
      '/run/argo/projection.sock',
    );
    for (final value in [
      '',
      'relative',
      ' /tmp/test.sock',
      '/tmp/test.sock ',
    ]) {
      expect(
        () => projectionEndpoint(
          {'ARGO_PROJECTION_SOCKET': value},
          'ARGO_PROJECTION_SOCKET',
          'projection.sock',
        ),
        throwsArgumentError,
      );
    }
  });

  test(
    'acknowledged pending and active configurations resist delayed responses',
    () async {
      final transport = _FakeTransport();
      final backend = AndroidAutoProjectionBackend(
        socketPath: '/tmp/test.sock',
        preferences: preferences,
        diagnostics: DiagnosticsService(),
        transportFactory: (_) async => transport,
      );
      await backend.start();
      transport.emit(const ProjectionIpcMessage(ProjectionIpcKind.hello));
      transport.emit(_capabilities());
      transport.emit(_configuration(1, preferences, preferences));
      final next = preferences.copyWith(dpi: 180);
      await backend.requestConfiguration(next);
      transport.emit(_configuration(2, next, preferences));
      expect(backend.configuration.pending, next);
      expect(backend.configuration.active, preferences);
      transport.emit(_configuration(1, preferences, preferences));
      transport.emit(_configuration(0, preferences, preferences));
      expect(backend.configuration.pending, next);
      await backend.requestConfiguration(next.copyWith(dpi: 200));
      transport.emit(_configuration(3, next, preferences, accepted: false));
      expect(backend.configuration.accepted, isFalse);
      expect(backend.configuration.pending, next);
      expect(backend.configuration.active, preferences);
      transport.emit(_configuration(3, next, null));
      expect(backend.configuration.active, isNull);
      transport.emit(_configuration(3, next, next));
      expect(backend.configuration.active, next);
      await backend.close();
    },
  );

  test('sidecar crash becomes recoverable failed backend state', () async {
    final diagnostics = DiagnosticsService();
    final transport = _FakeTransport();
    final backend = AndroidAutoProjectionBackend(
      socketPath: '/tmp/test.sock',
      preferences: preferences,
      diagnostics: diagnostics,
      transportFactory: (_) async => transport,
    );
    await backend.start();
    transport.emit(const ProjectionIpcMessage(ProjectionIpcKind.hello));
    transport.emit(_capabilities());
    expect(backend.current.backendAvailable, isTrue);

    await transport.crash();
    await Future<void>.delayed(Duration.zero);
    expect(backend.current.backendAvailable, isFalse);
    expect(backend.current.failureMessage, contains('disconnected'));
    expect(diagnostics.latest?.source, 'projection.androidAuto');
    await backend.close();
  });

  test(
    'sidecar metadata drives generic device and session lifecycle',
    () async {
      final transport = _FakeTransport();
      final backend = AndroidAutoProjectionBackend(
        socketPath: '/tmp/test.sock',
        preferences: preferences,
        diagnostics: DiagnosticsService(),
        transportFactory: (_) async => transport,
      );
      await backend.start();
      transport.emit(const ProjectionIpcMessage(ProjectionIpcKind.hello));
      transport.emit(_capabilities());
      transport.emit(
        ProjectionIpcMessage(
          ProjectionIpcKind.device,
          (ProjectionIpcWriter()
                ..string('phone')
                ..string('Test phone')
                ..uint8(ProjectionProtocol.androidAuto.index)
                ..uint8(ProjectionTransport.usb.index))
              .takeBytes(),
        ),
      );
      transport.emit(
        ProjectionIpcMessage(
          ProjectionIpcKind.session,
          (ProjectionIpcWriter()
                ..string('session')
                ..string('phone')
                ..uint8(ProjectionSessionState.connecting.index)
                ..string('')
                ..uint32(0))
              .takeBytes(),
        ),
      );

      expect(backend.current.devices.single.displayName, 'Test phone');
      expect(
        backend.current.sessions.single.state,
        ProjectionSessionState.connecting,
      );
      await backend.activate('session');
      expect(backend.current.activeSessionId, 'session');
      expect(transport.sent.last.kind, ProjectionIpcKind.activate);
      await backend.close();
    },
  );
}

final class _FakeTransport implements ProjectionControlTransport {
  final controller = StreamController<ProjectionIpcMessage>.broadcast(
    sync: true,
  );
  final sent = <ProjectionIpcMessage>[];
  @override
  Stream<ProjectionIpcMessage> get messages => controller.stream;
  void emit(ProjectionIpcMessage message) => controller.add(message);
  Future<void> crash() => controller.close();
  @override
  Future<void> send(ProjectionIpcMessage message) async => sent.add(message);
  @override
  Future<void> close() async {
    if (!controller.isClosed) await controller.close();
  }
}

ProjectionIpcMessage _capabilities() {
  final hex = File('test/fixtures/projection/ipc_v8_capabilities.hex')
      .readAsStringSync()
      .trim();
  final bytes = [
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
  return ProjectionIpcDecoder().add(bytes).single;
}

ProjectionIpcMessage _configuration(
  int revision,
  ProjectionPreferences pending,
  ProjectionPreferences? active, {
  bool accepted = true,
}) {
  final w = ProjectionIpcWriter()
    ..uint32(revision)
    ..uint8(accepted ? 1 : 0)
    ..string(accepted ? '' : 'Unsupported request');
  void display(ProjectionPreferences p) {
    w
      ..uint16(p.width)
      ..uint16(p.height)
      ..uint16(p.dpi)
      ..uint8(p.framesPerSecond)
      ..uint8(p.driverSide.index);
    for (final v in [p.viewInsets, p.safeInsets]) {
      w
        ..uint16(v.left.toInt())
        ..uint16(v.top.toInt())
        ..uint16(v.right.toInt())
        ..uint16(v.bottom.toInt());
    }
  }

  display(pending);
  w.string(active == null ? '' : 'session');
  if (active != null) display(active);
  return ProjectionIpcMessage(ProjectionIpcKind.configuration, w.takeBytes());
}

final class _BackendProjection implements ProjectionService {
  _BackendProjection(this.backend);
  final ProjectionBackend backend;
  @override
  ProjectionSnapshot get current => backend.current;
  @override
  Stream<ProjectionSnapshot> get changes => backend.changes;
  @override
  Future<void> sendButton(
    String sessionId,
    ProjectionInputButton button, {
    required bool pressed,
  }) => backend.sendButton(sessionId, button, pressed: pressed);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _AbsentCarPlay implements ProjectionBackend {
  @override
  ProjectionProtocol get protocol => ProjectionProtocol.carPlay;
  @override
  ProjectionSnapshot get current => const ProjectionSnapshot.disabled();
  @override
  Stream<ProjectionSnapshot> get changes => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ProjectionIpcMessage _fixture(String name) {
  final hex = File('test/fixtures/projection/$name').readAsStringSync().trim();
  return ProjectionIpcDecoder().add([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]).single;
}

void _announcePhone(
  _FakeTransport transport, {
  ProjectionSessionState state = ProjectionSessionState.ready,
}) {
  transport.emit(
    ProjectionIpcMessage(
      ProjectionIpcKind.device,
      (ProjectionIpcWriter()
            ..string('device')
            ..string('Phone')
            ..uint8(0)
            ..uint8(0))
          .takeBytes(),
    ),
  );
  transport.emit(
    ProjectionIpcMessage(
      ProjectionIpcKind.session,
      (ProjectionIpcWriter()
            ..string('aa-wired:device')
            ..string('device')
            ..uint8(state.index)
            ..string('')
            ..uint32(0))
          .takeBytes(),
    ),
  );
}

ProjectionIpcMessage _mediaMetadata({
  int revision = 3,
  int commands = 31,
  bool received = true,
  String? malformed,
}) {
  final writer = ProjectionIpcWriter()
    ..string('aa-wired:device')
    ..string('device')
    ..uint32(revision);
  void uint64(int value) {
    writer
      ..uint32(value >> 32)
      ..uint32(value & 0xffffffff);
  }

  uint64(1700000000000);
  writer.uint8(received ? 1 : 0);
  void text(String? value) {
    writer.uint8(value == null ? 0 : 1);
    if (value != null) writer.string(value);
  }

  void time(int? value) {
    writer.uint8(value == null ? 0 : 1);
    if (value != null) uint64(value);
  }

  text(received ? 'Track' : null);
  text(received ? 'Artist' : null);
  text(received ? 'Album' : null);
  writer.uint8(received ? 2 : 0);
  text(received ? 'Player' : null);
  time(received ? 42000 : null);
  time(received ? 123000 : null);
  text('Phone');
  text(null);
  text(null);
  writer
    ..uint8(255)
    ..uint8(0);
  text(null);
  text(received ? 'Roadtrip' : null);
  writer
    ..uint8(
      malformed == 'shuffle'
          ? 3
          : received
          ? 2
          : 0,
    )
    ..uint8(received ? 1 : 0)
    ..uint8(received ? 2 : 0)
    ..uint8(
      malformed == 'rating'
          ? 2
          : received
          ? 1
          : 0,
    );
  if (received) writer.uint32(0xffffffff);
  writer.uint8(malformed == 'commands' ? 32 : commands);
  var bytes = writer.takeBytes();
  if (malformed == 'truncated') bytes = bytes.sublist(0, bytes.length - 1);
  return ProjectionIpcMessage(ProjectionIpcKind.metadata, bytes);
}
