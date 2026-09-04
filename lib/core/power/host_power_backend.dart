/// Selects whether Argo may invoke privileged host power operations.
enum HostPowerBackend {
  disabled('disabled'),
  linuxSystemd('linux-systemd');

  const HostPowerBackend(this.wireValue);

  final String wireValue;

  static HostPowerBackend fromEnvironment(Map<String, String> environment) {
    final value = environment['ARGO_HOST_POWER_BACKEND']?.trim();
    if (value == null || value.isEmpty || value == disabled.wireValue) {
      return disabled;
    }
    if (value == linuxSystemd.wireValue) return linuxSystemd;
    throw ArgumentError.value(
      value,
      'ARGO_HOST_POWER_BACKEND',
      'Expected "disabled" or "linux-systemd"',
    );
  }
}
