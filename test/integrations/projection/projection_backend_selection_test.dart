import 'dart:async';
import 'dart:io';

import 'package:argo/core/diagnostics/diagnostics_service.dart';
import 'package:argo/core/projection/disabled_projection_backend.dart';
import 'package:argo/core/projection/projection_preferences.dart';
import 'package:argo/core/projection/projection_types.dart';
import 'package:argo/integrations/projection/android_auto_projection_backend.dart';
import 'package:argo/integrations/projection/android_auto_identity.dart';
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

  test('missing Android Auto identity fails closed', () async {
    await expectLater(
      selectProjectionBackend(
        environment: const {'ARGO_PROJECTION_BACKEND': 'android-auto'},
        preferences: preferences,
        diagnostics: DiagnosticsService(),
        isLinux: true,
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('configured Linux backend uses validated identity', () async {
    var validated = false;
    final backend = await selectProjectionBackend(
      environment: const {
        'ARGO_PROJECTION_BACKEND': 'android-auto',
        'ARGO_ANDROID_AUTO_CERT_FILE': '/identity/cert.pem',
        'ARGO_ANDROID_AUTO_KEY_FILE': '/identity/key.pem',
      },
      preferences: preferences,
      diagnostics: DiagnosticsService(),
      isLinux: true,
      identityValidator: (identity) async {
        validated = true;
        expect(identity.privateKeyFile.path, contains('identity'));
      },
      transportFactory: (_) async => _FakeTransport(),
    );
    expect(validated, isTrue);
    expect(backend, isA<AndroidAutoProjectionBackend>());
  });

  test('sidecar crash becomes recoverable failed backend state', () async {
    final diagnostics = DiagnosticsService();
    final transport = _FakeTransport();
    final backend = AndroidAutoProjectionBackend(
      socketPath: '/tmp/test.sock',
      identity: AndroidAutoIdentity(
        certificateFile: File('cert.pem'),
        privateKeyFile: File('key.pem'),
      ),
      preferences: preferences,
      diagnostics: diagnostics,
      transportFactory: (_) async => transport,
    );
    await backend.start();
    transport.emit(const ProjectionIpcMessage(ProjectionIpcKind.hello));
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
        identity: AndroidAutoIdentity(
          certificateFile: File('cert.pem'),
          privateKeyFile: File('key.pem'),
        ),
        preferences: preferences,
        diagnostics: DiagnosticsService(),
        transportFactory: (_) async => transport,
      );
      await backend.start();
      transport.emit(const ProjectionIpcMessage(ProjectionIpcKind.hello));
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
