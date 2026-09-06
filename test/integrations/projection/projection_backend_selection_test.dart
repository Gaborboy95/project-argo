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
        12,
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
                ..string(''))
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
  final hex = File('test/fixtures/projection/ipc_v2_capabilities.hex')
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
  }

  display(pending);
  w.string(active == null ? '' : 'session');
  if (active != null) display(active);
  return ProjectionIpcMessage(ProjectionIpcKind.configuration, w.takeBytes());
}
