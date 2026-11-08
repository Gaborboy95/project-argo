/// Runtime-only diagnostics; independent of the native renderer test source.
final class ProjectionPresentationOptions {
  const ProjectionPresentationOptions({
    required this.geometryDiagnostics,
    this.inputDiagnostics = false,
  });
  final bool geometryDiagnostics;
  final bool inputDiagnostics;
}
