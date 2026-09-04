import 'dart:io';

import '../../core/power/host_power_backend.dart';
import '../../core/power/host_power_controller.dart';
import 'linux_systemd_host_power_controller.dart';

HostPowerController selectHostPowerController({
  required Map<String, String> environment,
  bool? isLinux,
  HostProcessRunner? processRunner,
}) {
  final backend = HostPowerBackend.fromEnvironment(environment);
  return switch (backend) {
    HostPowerBackend.disabled => const DisabledHostPowerController(),
    HostPowerBackend.linuxSystemd => _linuxSystemdController(
      isLinux: isLinux ?? Platform.isLinux,
      processRunner: processRunner,
    ),
  };
}

HostPowerController _linuxSystemdController({
  required bool isLinux,
  HostProcessRunner? processRunner,
}) {
  if (!isLinux) {
    throw UnsupportedError(
      'ARGO_HOST_POWER_BACKEND=linux-systemd is supported only on Linux.',
    );
  }
  return LinuxSystemdHostPowerController(processRunner: processRunner);
}
