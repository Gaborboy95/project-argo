import 'dart:io';

import '../../core/diagnostics/diagnostics_service.dart';
import '../../core/projection/disabled_projection_backend.dart';
import '../../core/projection/projection_backend.dart';
import '../../core/projection/projection_backend_type.dart';
import '../../core/projection/projection_preferences.dart';
import '../../core/projection/projection_render_test.dart';
import 'android_auto_identity.dart';
import 'android_auto_projection_backend.dart';
import 'projection_ipc.dart';

typedef AndroidAutoIdentityValidator = Future<void> Function(
  AndroidAutoIdentity identity,
);

Future<ProjectionBackend> selectProjectionBackend({
  required Map<String, String> environment,
  required ProjectionPreferences preferences,
  required DiagnosticsService diagnostics,
  bool? isLinux,
  ProjectionControlTransportFactory? transportFactory,
  AndroidAutoIdentityValidator? identityValidator,
}) async {
  ProjectionRenderTest.fromEnvironment(environment);
  final type = ProjectionBackendType.fromEnvironment(environment);
  if (type == ProjectionBackendType.disabled) {
    return const DisabledProjectionBackend();
  }
  if (!(isLinux ?? Platform.isLinux)) {
    throw UnsupportedError(
      'ARGO_PROJECTION_BACKEND=android-auto is currently supported only on Linux.',
    );
  }

  final identity = AndroidAutoIdentity.fromEnvironment(environment);
  await (identityValidator ?? (value) => value.validate())(identity);
  final socket = environment['ARGO_PROJECTION_SOCKET']?.trim();
  return AndroidAutoProjectionBackend(
    socketPath: socket == null || socket.isEmpty
        ? '/run/argo/projection.sock'
        : socket,
    identity: identity,
    preferences: preferences,
    diagnostics: diagnostics,
    transportFactory: transportFactory,
  );
}
