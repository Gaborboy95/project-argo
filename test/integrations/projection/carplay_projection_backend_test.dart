import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:argo/core/projection/projection_types.dart';
import 'package:argo/integrations/projection/carplay_projection_backend.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'native metadata, selection and touch use one bounded session',
    () async {
      final directory = await Directory.systemTemp.createTemp('carplay-ui-');
      final path = '${directory.path}/control';
      final server = await ServerSocket.bind(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
      );
      final parameters = ByteData(40);
      parameters.buffer.asUint8List().setAll(0, [65, 82, 86, 50]);
      parameters.setUint32(4, 1);
      parameters.buffer.asUint8List().setAll(8, [2, 1, 1, 2, 2, 2]);
      parameters.setUint16(14, 1280);
      parameters.setUint16(16, 720);
      parameters.setUint16(18, 30);
      parameters.setUint16(20, 1);
      parameters.setUint64(24, 7);
      var selected = false;
      var microphoneMuted = true;
      var microphoneSource = 'fixture_source';
      var malformed = false;
      final requests = <Map<String, dynamic>>[];
      final connections = <Socket>[];
      final subscription = server.listen((socket) async {
        connections.add(socket);
        final line = await utf8.decoder
            .bind(socket)
            .transform(const LineSplitter())
            .first;
        final request = jsonDecode(line) as Map<String, dynamic>;
        requests.add(request);
        if (request['action'] == 'activate') selected = true;
        socket.writeln(
          jsonEncode(
            request['action'] == 'status'
                ? {
                    'contract': 1,
                    'microphone_policy': true,
                    'microphone_source': true,
                    'available': true,
                    'session': 7,
                    'device': 'fixture',
                    'name': 'Fixture phone',
                    'recorded': true,
                    'selected': selected,
                    'visible': selected,
                    'audio': <Object>[],
                    'video': {
                      'width': malformed ? 9000 : 1280,
                      'height': 720,
                      'fps': 30,
                      'presentation_revision': selected ? 1 : 0,
                      'codec': 'h264',
                      'first_frame': true,
                      'native_parameters': parameters.buffer
                          .asUint8List()
                          .toList(),
                    },
                  }
                : {'ok': true},
          ),
        );
        await socket.flush();
        await socket.close();
      });
      final backend = CarPlayProjectionBackend(
        socketPath: path,
        microphoneMuted: () => microphoneMuted,
        selectedMicrophone: () => microphoneSource,
      );
      addTearDown(() async {
        await backend.close();
        for (final socket in connections) {
          socket.destroy();
        }
        await subscription.cancel();
        await server.close();
        await directory.delete(recursive: true);
      });
      await backend.start();
      expect(
        requests
            .where((r) => r['action'] == 'microphone_source')
            .single['source'],
        'fixture_source',
      );
      await backend.sendButton(
        '7',
        ProjectionInputButton.voiceAssistant,
        pressed: true,
      );
      await backend.sendButton(
        '7',
        ProjectionInputButton.voiceAssistant,
        pressed: false,
      );
      expect(
        requests
            .where((request) => request['action'] == 'siri')
            .map((request) => request['pressed']),
        [true, false],
      );

      expect(
        backend.current.sessions.single.state,
        ProjectionSessionState.streaming,
      );
      expect(backend.current.activeSessionId, isNull);
      expect(
        backend
            .current
            .sessions
            .single
            .videoStreams
            .single
            .nativeViewParameters,
        parameters.buffer.asUint8List(),
      );
      expect(
        requests
            .where((r) => r['action'] == 'microphone_mute')
            .map((r) => r['muted']),
        [true],
      );
      microphoneMuted = false;
      await backend.connect('fixture');
      expect(
        requests
            .where((r) => r['action'] == 'microphone_mute')
            .map((r) => r['muted']),
        [true, false],
      );
      microphoneSource = 'second_source';
      await backend.activate('7');
      expect(
        requests
            .where((r) => r['action'] == 'microphone_source')
            .last['source'],
        'second_source',
      );
      expect(backend.current.activeSessionId, '7');
      expect(
        backend
            .current
            .sessions
            .single
            .videoStreams
            .single
            .presentationRevision,
        1,
      );
      await backend.sendTouch(
        '7',
        const ProjectionTouch(
          pointerId: 1,
          phase: ProjectionTouchPhase.down,
          x: .25,
          y: .75,
        ),
      );
      expect(requests.last, {
        'action': 'touch',
        'session': 7,
        'pointer': 1,
        'phase': 'down',
        'x': .25,
        'y': .75,
      });
      await expectLater(backend.activate('8'), throwsStateError);
      malformed = true;
      await backend.activate('7');
      expect(backend.current.backendAvailable, isFalse);
      expect(backend.current.sessions, isEmpty);
    },
  );

  test('unsupported rotary and non-Siri buttons fail explicitly', () async {
    final backend = CarPlayProjectionBackend(
      socketPath: '/tmp/unused-carplay-control',
    );
    for (final button in ProjectionInputButton.values) {
      if (button == ProjectionInputButton.voiceAssistant) continue;
      for (final pressed in [true, false]) {
        await expectLater(
          backend.sendButton('7', button, pressed: pressed),
          throwsUnsupportedError,
        );
      }
    }
    await expectLater(backend.sendRotary('7', 1), throwsUnsupportedError);
    await backend.close();
  });

  test('rejects invalid socket and polling configuration', () {
    expect(
      () => CarPlayProjectionBackend(socketPath: 'relative'),
      throwsArgumentError,
    );
    expect(
      () => CarPlayProjectionBackend(
        socketPath: '/tmp/control',
        pollInterval: Duration.zero,
      ),
      throwsArgumentError,
    );
  });
}
