import 'projection_backend_type.dart';

/// Local renderer diagnostic configuration; never a projection session/protocol.
final class ProjectionRenderTest {
  const ProjectionRenderTest({required this.enabled});

  factory ProjectionRenderTest.fromEnvironment(
    Map<String, String> environment,
  ) {
    final value = environment['ARGO_PROJECTION_RENDER_TEST'];
    if (value != null && value != '0' && value != '1') {
      throw ArgumentError('ARGO_PROJECTION_RENDER_TEST must be 0 or 1.');
    }
    final enabled = value == '1';
    if (enabled &&
        ProjectionBackendType.fromEnvironment(environment) !=
            ProjectionBackendType.disabled) {
      throw ArgumentError(
        'ARGO_PROJECTION_RENDER_TEST=1 requires ARGO_PROJECTION_BACKEND=disabled.',
      );
    }
    return ProjectionRenderTest(enabled: enabled);
  }

  final bool enabled;
}
