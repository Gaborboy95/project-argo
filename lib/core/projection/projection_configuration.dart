import 'projection_preferences.dart';

/// Metadata only. Rates describe selected PCM caps, not observed device output.
final class ProjectionAudioFormat {
  const ProjectionAudioFormat(this.role, this.rate, this.bits, this.channels);
  final String role;
  final int rate, bits, channels;
}

final class ProjectionCapabilities {
  const ProjectionCapabilities({
    required this.resolutions,
    required this.frameRates,
    required this.minimumDpi,
    required this.maximumDpi,
    required this.defaults,
    required this.audio,
  });
  final List<(int, int)> resolutions;
  final List<int> frameRates;
  final int minimumDpi, maximumDpi;
  final ProjectionPreferences defaults;
  final List<ProjectionAudioFormat> audio;
  bool supports(ProjectionPreferences p) =>
      resolutions.contains((p.width, p.height)) &&
      frameRates.contains(p.framesPerSecond) &&
      p.dpi >= minimumDpi &&
      p.dpi <= maximumDpi;
}

enum ProjectionReadiness {
  unavailable,
  ready,
  identityMissing,
  identityInvalid,
  backendFailure,
}

final class ProjectionConfigurationState {
  const ProjectionConfigurationState({
    this.readiness = ProjectionReadiness.unavailable,
    this.message = 'Projection daemon unavailable; saved preferences are not backend-validated.',
    this.capabilities,
    this.pending,
    this.active,
    this.sessionId,
    this.revision = 0,
    this.accepted = true,
    this.rejection,
  });
  final ProjectionReadiness readiness;
  final String message;
  final ProjectionCapabilities? capabilities;
  final ProjectionPreferences? pending, active;
  final String? sessionId;
  final int revision;
  final bool accepted;
  final String? rejection;
}

/// Optional control extension; disabled/test backends never contact the daemon.
abstract interface class ProjectionConfigurationBackend {
  ProjectionConfigurationState get configuration;
  Stream<ProjectionConfigurationState> get configurationChanges;
  Future<void> requestConfiguration(ProjectionPreferences preferences);
}
