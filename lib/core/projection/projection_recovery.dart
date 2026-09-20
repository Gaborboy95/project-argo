import '../diagnostics/service_failure.dart';

/// A failed switch belongs to one presentation decision, never to a reconnect.
final class ProjectionSwitchRecovery {
  const ProjectionSwitchRecovery({
    required this.generation,
    required this.target,
    required this.targetName,
    this.previous,
    this.previousName,
    required this.failure,
  });
  final int generation;
  final String target, targetName;
  final String? previous, previousName;
  final ServiceFailure failure;
}

abstract interface class ProjectionRecovery {
  void invalidateRecovery();
  Future<void> recover(
    ProjectionSwitchRecovery decision, {
    bool returnToPrevious = false,
  });
}
