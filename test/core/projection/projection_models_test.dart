import 'dart:io';

import 'package:argo/core/projection/projection_backend_type.dart';
import 'package:argo/core/projection/projection_models.dart';
import 'package:argo/core/projection/projection_types.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('projection protocol and transport are orthogonal', () {
    const device = ProjectionDevice(
      id: 'phone',
      displayName: 'Phone',
      protocol: ProjectionProtocol.carPlay,
      transport: ProjectionTransport.usb,
    );

    expect(device.protocol, ProjectionProtocol.carPlay);
    expect(device.transport, ProjectionTransport.usb);
  });

  test('projection backend defaults disabled and rejects invalid values', () {
    expect(
      ProjectionBackendType.fromEnvironment(const {}),
      ProjectionBackendType.disabled,
    );
    expect(
      ProjectionBackendType.fromEnvironment(const {
        'ARGO_PROJECTION_BACKEND': 'android-auto',
      }),
      ProjectionBackendType.androidAuto,
    );
    expect(
      () => ProjectionBackendType.fromEnvironment(const {
        'ARGO_PROJECTION_BACKEND': 'magic',
      }),
      throwsArgumentError,
    );
  });

  test('Dart projection API contains no raw media payload type', () {
    final root = Directory('lib/core/projection');
    final source = root
        .listSync(recursive: true)
        .whereType<File>()
        .map((file) => file.readAsStringSync())
        .join('\n');

    expect(source, isNot(contains('Uint8List')));
    expect(source, isNot(contains('frameBytes')));
    expect(source, isNot(contains('pcmBytes')));
  });
}
