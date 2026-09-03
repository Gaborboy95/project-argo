/// Selects the external-input policy used by the composed application.
enum ArgoRuntimeMode {
  production,
  simulation;

  /// Production is the only implicit mode. Simulation must be explicit.
  static ArgoRuntimeMode fromEnvironment(Map<String, String> environment) {
    final raw = environment['ARGO_MODE'];
    if (raw == null) return ArgoRuntimeMode.production;

    return switch (raw.trim().toLowerCase()) {
      'production' => ArgoRuntimeMode.production,
      'simulation' => ArgoRuntimeMode.simulation,
      _ => throw ArgumentError.value(
        raw,
        'ARGO_MODE',
        'Must be "production" or "simulation"',
      ),
    };
  }
}
