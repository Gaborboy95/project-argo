/// The narrow privileged host operation Argo may perform.
abstract interface class HostPowerController {
  /// Whether this controller can perform an actual host operation.
  bool get isEnabled;

  Future<void> suspend();
}

/// Safe default controller for development and unsupported deployments.
final class DisabledHostPowerController implements HostPowerController {
  const DisabledHostPowerController();

  @override
  bool get isEnabled => false;

  @override
  Future<void> suspend() async {}
}
