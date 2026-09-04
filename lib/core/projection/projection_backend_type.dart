enum ProjectionBackendType {
  disabled('disabled'),
  androidAuto('android-auto');

  const ProjectionBackendType(this.environmentValue);
  final String environmentValue;

  static ProjectionBackendType fromEnvironment(
    Map<String, String> environment,
  ) {
    final configured = environment['ARGO_PROJECTION_BACKEND']?.trim();
    if (configured == null || configured.isEmpty) return disabled;
    for (final type in values) {
      if (type.environmentValue == configured) return type;
    }
    throw ArgumentError.value(
      configured,
      'ARGO_PROJECTION_BACKEND',
      'Expected disabled or android-auto',
    );
  }
}
