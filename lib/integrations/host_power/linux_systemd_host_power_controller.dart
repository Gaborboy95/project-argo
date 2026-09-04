import 'dart:io';

import '../../core/power/host_power_controller.dart';

typedef HostProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

final class HostPowerCommandException implements Exception {
  const HostPowerCommandException({
    required this.exitCode,
    required this.standardError,
  });

  final int exitCode;
  final String standardError;

  @override
  String toString() {
    final detail = standardError.trim();
    return 'systemctl suspend failed with exit code $exitCode'
        '${detail.isEmpty ? '.' : ': $detail'}';
  }
}

/// Linux implementation using systemd without a shell or privilege wrapper.
final class LinuxSystemdHostPowerController implements HostPowerController {
  LinuxSystemdHostPowerController({HostProcessRunner? processRunner})
    : _processRunner = processRunner ?? _runProcess;

  final HostProcessRunner _processRunner;

  @override
  bool get isEnabled => true;

  @override
  Future<void> suspend() async {
    final result = await _processRunner('systemctl', const ['suspend']);
    if (result.exitCode != 0) {
      throw HostPowerCommandException(
        exitCode: result.exitCode,
        standardError: result.stderr.toString(),
      );
    }
  }

  static Future<ProcessResult> _runProcess(
    String executable,
    List<String> arguments,
  ) => Process.run(executable, arguments);
}
