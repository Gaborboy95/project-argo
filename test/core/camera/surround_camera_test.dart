import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:argo/core/camera/camera_service.dart';
import 'package:argo/core/camera/surround_camera_service.dart';
import 'package:argo/core/camera/surround_jobs.dart';
import 'package:argo/core/settings/app_setting_keys.dart';
import 'package:argo/core/settings/settings_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'camera_test.dart' show MemoryCameraSettings;

void main() {
  test('Dart agrees with standalone protocol compatibility fixtures', () {
    final fixture = jsonDecode(
      File('test/fixtures/camera/surround_protocol.json').readAsStringSync(),
    ) as Map;
    for (final value in fixture['valid'] as List) {
      expect(
        () => SurroundControlDecoder.validateEnvelope(
          Map<String, dynamic>.from(value as Map),
        ),
        returnsNormally,
      );
    }
    for (final value in fixture['invalid'] as List) {
      expect(
        () => SurroundControlDecoder.validateEnvelope(
          Map<String, dynamic>.from(value as Map),
        ),
        throwsFormatException,
      );
    }
  });

  test(
    'actual standalone service negotiates Dart leases, snapshots and persistent worker jobs',
    () async {
      final executable = Platform.environment['SURROUND_TEST_DAEMON']!;
      final root = await Directory.systemTemp.createTemp(
        'surround-real-client',
      );
      final runtime = Directory('${root.path}/runtime');
      final process = await Process.start(
        executable,
        ['--test-source'],
        environment: {
          'SURROUND_RUNTIME_DIR': runtime.path,
          'SURROUND_STATE_DIR': '${root.path}/state',
        },
      );
      final errors = <int>[];
      process.stderr.listen(errors.addAll);
      unawaited(process.stdout.drain<void>());
      final settings = await SettingsService.load(
        schema: AppSettingKeys.createSchema(),
        store: MemoryCameraSettings(),
      );
      final service = SurroundCameraService(
        settings: settings,
        environment: {'SURROUND_RUNTIME_DIR': runtime.path},
        registerNative: false,
      );
      try {
        for (
          var i = 0;
          i < 50 && !await File('${runtime.path}/control.sock').exists();
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        await service.initialize();
        expect(
          service.current.available,
          isTrue,
          reason: service.current.error,
        );
        expect(service.current.devices.length, 8);
        final id = service.current.devices.first.stableId;
        await service.assign(CameraRole.rear, id);
        await service.start(CameraRole.rear);
        final snapshot = await service.command('snapshot', {
          'camera_id': id,
        }, true);
        expect(snapshot['frame']['format'], 'BGRx');
        expect(await File(snapshot['path'] as String).exists(), isTrue);
        final session = await SurroundJob(service).run('calibration', {
          'op': 'start_session',
          'board': {'columns': 9, 'rows': 6, 'square_m': 0.025},
        });
        expect(session['session_id'], isA<String>());
        await service.stop();
        final status = await service.command('status');
        expect(status['subscriptions'], 0);
        final recorder = await service.command('recording', {
          'action': 'status',
        }, true);
        expect(recorder['state'], 'idle');
        await service.close();
        expect(process.kill(ProcessSignal.sigterm), isTrue);
        await process.exitCode.timeout(const Duration(seconds: 5));
      } on Object {
        stderr.writeln(
          'Synthetic daemon stderr: ${utf8.decode(errors, allowMalformed: true)}',
        );
        rethrow;
      } finally {
        await service.close();
        await settings.close();
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
        await root.delete(recursive: true);
      }
    },
    skip: Platform.environment['SURROUND_TEST_DAEMON'] == null
        ? 'Set SURROUND_TEST_DAEMON for real Rust/Dart integration (synthetic sources only)'
        : false,
  );

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
          if (request['op'] == 'unsubscribe') {
            expect(request['args']['subscription_id'], isA<int>());
          }
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
            'subscribe' => {'subscription_id': 1},
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
      environment: {'SURROUND_RUNTIME_DIR': runtime.path},
      registerNative: false,
    );
    await service.initialize();
    expect(service.current.rearUsable, isTrue);
    await service.start(CameraRole.rear);
    await service.start(CameraRole.rear);
    expect(commands.where((op) => op == 'subscribe').length, 1);
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
