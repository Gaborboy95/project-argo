import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:argo/core/camera/camera_service.dart';
import 'package:argo/core/camera/surround_camera_service.dart';
import 'package:argo/core/settings/app_setting_keys.dart';
import 'package:argo/core/settings/settings_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'camera_test.dart' show MemoryCameraSettings;

void main() {
  test('external protocol bounds, fragmentation and message types', () {
    final bytes = SurroundControlDecoder.encode(3, 'status', {});
    final decoder = SurroundControlDecoder();
    final values = <Map<String, dynamic>>[];
    for (final byte in bytes) {
      values.addAll(decoder.add([byte]));
    }
    expect(values.single['major'], 1);
    expect(values.single['id'], 3);
    expect(
      () => SurroundControlDecoder().add([0, 1, 0, 1]).toList(),
      throwsFormatException,
    );
    expect(
      () => SurroundControlDecoder().add([0, 0, 0, 0]).toList(),
      throwsFormatException,
    );
    expect(
      () => SurroundControlDecoder().add([0, 0, 0, 2, 91, 93]).toList(),
      throwsFormatException,
    );
  });
  test('external display EOF releases only its lease; engine is never launched or stopped', () async {
    final runtime = await Directory.systemTemp.createTemp(
      'surround-client-test',
    );
    final server = await ServerSocket.bind(
      InternetAddress(
        '${runtime.path}/control.sock',
        type: InternetAddressType.unix,
      ),
      0,
    );
    final commands = <String>[];
    final sockets = <Socket>[];
    final listener = server.listen((socket) {
      sockets.add(socket);
      final decoder = SurroundControlDecoder();
      socket.listen((bytes) {
        for (final request in decoder.add(bytes)) {
          commands.add(request['op'] as String);
          final result = switch (request['op']) {
            'status' => {
              'devices': [
                {
                  'stableId': 'by-path:port',
                  'displayName': 'Capture adapter',
                  'node': '/dev/video42',
                },
              ],
              'assignments': {'rear': 'by-path:port'},
              'groups': {},
              'streams': [],
            },
            'subscribe' => {'subscription_id': 'lease1'},
            _ => <String, dynamic>{},
          };
          final body = utf8.encode(
            jsonEncode({
              'major': 1,
              'minor': 0,
              'id': request['id'],
              'ok': true,
              'result': result,
            }),
          );
          socket.add([
            ...(ByteData(4)..setUint32(0, body.length)).buffer.asUint8List(),
            ...body,
          ]);
        }
      });
    });
    final settings = await SettingsService.load(
      schema: AppSettingKeys.createSchema(),
      store: MemoryCameraSettings(),
    );
    final service = SurroundCameraService(
      settings: settings,
      environment: {'SURROUND_CAMERA_RUNTIME': runtime.path},
      registerNative: false,
    );
    await service.initialize();
    expect(service.current.rearUsable, isTrue);
    await service.start(CameraRole.rear);
    await service.close();
    expect(
      commands,
      containsAll(['hello', 'status', 'subscribe', 'unsubscribe']),
    );
    expect(commands, isNot(contains('close')));
    expect(commands, isNot(contains('stop')));
    for (final socket in sockets) {
      socket.destroy();
    }
    await listener.cancel();
    await server.close();
    await settings.close();
    await runtime.delete(recursive: true);
  });
}
