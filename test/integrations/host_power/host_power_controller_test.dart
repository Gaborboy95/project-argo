import 'dart:io';

import 'package:argo/core/power/host_power_backend.dart';
import 'package:argo/core/power/host_power_controller.dart';
import 'package:argo/integrations/host_power/host_power_controller_selection.dart';
import 'package:argo/integrations/host_power/linux_systemd_host_power_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('host power backend defaults to disabled', () {
    expect(
      HostPowerBackend.fromEnvironment(const {}),
      HostPowerBackend.disabled,
    );
    expect(
      selectHostPowerController(environment: const {}),
      isA<DisabledHostPowerController>(),
    );
  });

  test('unknown host power backend fails clearly', () {
    expect(
      () => HostPowerBackend.fromEnvironment(const {
        'ARGO_HOST_POWER_BACKEND': 'something-else',
      }),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.name,
          'name',
          'ARGO_HOST_POWER_BACKEND',
        ),
      ),
    );
  });

  test('selects Linux systemd backend when running on Linux', () {
    final controller = selectHostPowerController(
      environment: const {'ARGO_HOST_POWER_BACKEND': 'linux-systemd'},
      isLinux: true,
      processRunner: (_, _) async => ProcessResult(1, 0, '', ''),
    );

    expect(controller, isA<LinuxSystemdHostPowerController>());
    expect(controller.isEnabled, isTrue);
  });

  test('rejects Linux systemd backend on non-Linux hosts', () {
    expect(
      () => selectHostPowerController(
        environment: const {'ARGO_HOST_POWER_BACKEND': 'linux-systemd'},
        isLinux: false,
      ),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('Linux backend invokes exactly systemctl suspend', () async {
    String? executable;
    List<String>? arguments;
    final controller = LinuxSystemdHostPowerController(
      processRunner: (value, values) async {
        executable = value;
        arguments = List.of(values);
        return ProcessResult(1, 0, '', '');
      },
    );

    await controller.suspend();

    expect(executable, 'systemctl');
    expect(arguments, const ['suspend']);
  });

  test('Linux backend invokes exactly systemctl poweroff', () async {
    String? executable;
    List<String>? arguments;
    final controller = LinuxSystemdHostPowerController(
      processRunner: (value, values) async {
        executable = value;
        arguments = List.of(values);
        return ProcessResult(1, 0, '', '');
      },
    );

    await controller.powerOff();

    expect(executable, 'systemctl');
    expect(arguments, const ['poweroff']);
  });

  test('Linux backend surfaces non-zero status and stderr', () async {
    final controller = LinuxSystemdHostPowerController(
      processRunner: (_, _) async =>
          ProcessResult(1, 5, '', 'permission denied'),
    );

    await expectLater(
      controller.suspend(),
      throwsA(
        isA<HostPowerCommandException>()
            .having((error) => error.exitCode, 'exitCode', 5)
            .having(
              (error) => error.toString(),
              'message',
              contains('permission denied'),
            ),
      ),
    );
  });

  test('disabled backend never invokes an OS command', () async {
    var processCalls = 0;
    final controller = selectHostPowerController(
      environment: const {'ARGO_HOST_POWER_BACKEND': 'disabled'},
      processRunner: (_, _) async {
        processCalls++;
        return ProcessResult(1, 0, '', '');
      },
    );

    await controller.suspend();
    await controller.powerOff();

    expect(controller.isEnabled, isFalse);
    expect(processCalls, 0);
  });
}
