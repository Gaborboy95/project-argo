import 'dart:typed_data';

import 'package:argo/integrations/projection/projection_ipc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bounded IPC round trips across fragmented input', () {
    const codec = ProjectionIpcCodec();
    final bytes = codec.encode(
      const ProjectionIpcMessage(ProjectionIpcKind.device, [1, 2, 3]),
    );
    final decoder = ProjectionIpcDecoder();

    expect(decoder.add(bytes.sublist(0, 5)), isEmpty);
    final decoded = decoder.add(bytes.sublist(5));
    expect(decoded.single.kind, ProjectionIpcKind.device);
    expect(decoded.single.payload, [1, 2, 3]);
  });

  test('malformed IPC and oversized payload are rejected', () {
    final old = const ProjectionIpcCodec().encode(
      const ProjectionIpcMessage(ProjectionIpcKind.hello),
    );
    old[5] = 1;
    expect(
      () => ProjectionIpcDecoder().add(old),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('matching Argo/daemon IPC v2'),
        ),
      ),
    );
    final decoder = ProjectionIpcDecoder();
    expect(() => decoder.add(Uint8List(12)), throwsFormatException);
    expect(
      () => const ProjectionIpcCodec().encode(
        ProjectionIpcMessage(
          ProjectionIpcKind.error,
          Uint8List(ProjectionIpcProtocol.maximumPayloadBytes + 1),
        ),
      ),
      throwsRangeError,
    );
  });

  test('typed field reader rejects truncation', () {
    final writer = ProjectionIpcWriter()..string('hello');
    final bytes = writer.takeBytes();
    expect(
      () => ProjectionIpcReader(bytes.sublist(0, bytes.length - 1)).string(),
      throwsFormatException,
    );
  });
}
