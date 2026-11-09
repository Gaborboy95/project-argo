import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:argo/core/projection/projection_types.dart';
import 'package:argo/core/media/media_state.dart';
import 'package:argo/integrations/projection/carplay_projection_backend.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('plugging a real mic into an active silence session preserves video and audio', () async {
    String? microphone = '';
    final fixture = await _MediaFixture.create(
      selectedMicrophone: () => microphone,
    );
    addTearDown(fixture.close);
    fixture.status.addAll({
      'microphone_source': true,
      'microphone_mode': 'silence',
      'selected': true,
      'visible': true,
      'media_commands': ['playPause'],
      'audio': [
        {
          'connection': 'music',
          'category': 'media',
          'rate': 44100,
          'channels': 2,
          'active': true,
        },
      ],
    });
    await fixture.backend.start();
    final initial = fixture.backend.current.sessions.single;
    expect(initial.audioStreams.single.active, isTrue);
    microphone = 'new.usb.adc';
    // activate performs a synchronous status refresh, so this checks a full
    // post-plug adapter cycle without relying on the background poll timer.
    await fixture.backend.activate('7');
    expect(fixture.backend.current.backendAvailable, isTrue);
    expect(fixture.backend.current.failure, isNull);
    expect(fixture.backend.current.activeSessionId, '7');
    final retained = fixture.backend.current.sessions.single;
    expect(retained.state, ProjectionSessionState.streaming);
    expect(retained.videoStreams, initial.videoStreams);
    expect(retained.audioStreams, initial.audioStreams);
    expect(
      fixture.requests.where((r) => r['action'] == 'microphone_source'),
      isEmpty,
    );
    await fixture.backend.sendButton(
      '7',
      ProjectionInputButton.playPause,
      pressed: true,
    );
    expect(fixture.requests.last['action'], 'media');
    // The next physical session can apply the microphone normally.
    fixture.replaceSession(8);
    fixture.status['microphone_mode'] = 'device';
    await fixture.waitUntil(
      () => fixture.backend.current.sessions.singleOrNull?.id == '8',
    );
    expect(
      fixture.requests.where((r) => r['action'] == 'microphone_source').single,
      {'action': 'microphone_source', 'session': 8, 'source': 'new.usb.adc'},
    );
  });

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
      parameters.setUint16(32, 320);
      parameters.setUint16(36, 320);
      var selected = false;
      var microphoneMuted = true;
      var microphoneSource = 'fixture_source';
      var malformed = false;
      String? transport;
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
                    'transport': ?transport,
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
        backend.current.sessions.single.device.transport,
        ProjectionTransport.usb,
      );
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
        backend.current.sessions.single.videoStreams.single.contentInsets,
        const ProjectionInsets(left: 320, right: 320),
      );
      expect(
        requests
            .where((r) => r['action'] == 'microphone_mute')
            .map((r) => r['muted']),
        [true],
      );
      microphoneMuted = false;
      transport = 'wireless';
      await backend.connect('fixture');
      expect(
        backend.current.sessions.single.device.transport,
        ProjectionTransport.wifi,
      );
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
      if ({
        ProjectionInputButton.voiceAssistant,
        ProjectionInputButton.playPause,
        ProjectionInputButton.play,
        ProjectionInputButton.pause,
        ProjectionInputButton.next,
        ProjectionInputButton.previous,
      }.contains(button)) {
        continue;
      }
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

  test('reported CarPlay track, artwork and phone power reach metadata without touching projection ownership', () async {
    final fixture = await _MediaFixture.create();
    addTearDown(fixture.close);
    fixture.status['media'] = _media();
    fixture.status['phone'] = {'battery_percent': 61, 'external_power': true};
    fixture.status['media_commands'] = [
      'previous',
      'play',
      'pause',
      'playPause',
      'next',
    ];
    await fixture.backend.start();
    final session = fixture.backend.current.sessions.single;
    final metadata = session.metadata!;
    expect(metadata.media?.title, 'Song');
    expect(metadata.media?.artist, 'Artist');
    expect(metadata.media?.album, 'Album');
    expect(metadata.media?.albumArtist, 'Album artist');
    expect(metadata.media?.genre, 'Genre');
    expect(metadata.media?.application, 'Music');
    expect(metadata.media?.applicationId, 'com.example.player');
    expect(metadata.media?.trackId, '0000000000000001');
    expect(
      metadata.media?.artworkPath,
      Platform.environment['XDG_RUNTIME_DIR'] == null ? isNull : _artworkPath,
    );
    expect(metadata.media?.playback, MediaPlaybackState.playing);
    expect(metadata.media?.positionMs, 1200);
    expect(metadata.media?.durationMs, 123000);
    expect(metadata.phone.batteryPercent, 61);
    expect(metadata.phone.externalPower, isTrue);
    expect(metadata.phone.charging, isNull);
    expect(metadata.mediaCommands, [
      'previous',
      'play',
      'pause',
      'playPause',
      'next',
    ]);
    expect(session.videoStreams.single.visible, isFalse);
    expect(
      fixture.requests.where(
        (r) => {'activate', 'visibility', 'gain'}.contains(r['action']),
      ),
      isEmpty,
    );
  });

  test('CarPlay media buttons send one native pulse each while video is hidden and reject stale or unsupported requests', () async {
    final fixture = await _MediaFixture.create();
    addTearDown(fixture.close);
    fixture.status['media_commands'] = [
      'previous',
      'play',
      'pause',
      'playPause',
      'next',
    ];
    // A ready receiver exposes controls even before a track update arrives.
    await fixture.backend.start();
    expect(fixture.backend.current.sessions.single.metadata?.media, isNull);
    for (final entry in [
      (ProjectionInputButton.playPause, 'playPause'),
      (ProjectionInputButton.play, 'play'),
      (ProjectionInputButton.pause, 'pause'),
      (ProjectionInputButton.next, 'next'),
      (ProjectionInputButton.previous, 'previous'),
    ]) {
      await fixture.backend.sendButton('7', entry.$1, pressed: true);
      await fixture.backend.sendButton('7', entry.$1, pressed: false);
    }
    expect(
      fixture.requests
          .where((r) => r['action'] == 'media')
          .map((r) => r['command']),
      ['playPause', 'play', 'pause', 'next', 'previous'],
    );
    expect(
      fixture.requests
          .where((r) => r['action'] == 'media')
          .every((r) => r['session'] == 7),
      isTrue,
    );
    expect(
      fixture.requests.where(
        (r) => {'activate', 'visibility', 'gain'}.contains(r['action']),
      ),
      isEmpty,
    );
    await expectLater(
      fixture.backend.sendButton(
        '8',
        ProjectionInputButton.playPause,
        pressed: true,
      ),
      throwsStateError,
    );
    fixture.status['media_commands'] = [];
    await fixture.waitUntil(
      () => fixture
          .backend
          .current
          .sessions
          .single
          .metadata!
          .mediaCommands
          .isEmpty,
    );
    await expectLater(
      fixture.backend.sendButton(
        '7',
        ProjectionInputButton.playPause,
        pressed: true,
      ),
      throwsUnsupportedError,
    );
    expect(fixture.requests.where((r) => r['action'] == 'media'), hasLength(5));
  });

  test('bad optional media and phone blocks retain same-epoch facts and valid native video, invalid capabilities disable controls', () async {
    final fixture = await _MediaFixture.create();
    addTearDown(fixture.close);
    fixture.status['media'] = _media();
    fixture.status['phone'] = {'battery_percent': 61};
    fixture.status['media_commands'] = ['playPause'];
    await fixture.backend.start();
    final original = fixture.backend.current.sessions.single;
    fixture.status['media'] = {
      'revision': 'wrong',
      'title': 'Broken',
      'duration_ms': -1,
    };
    fixture.status['phone'] = {'battery_percent': 400};
    fixture.status['media_commands'] = ['seek'];
    await fixture.waitUntil(
      () => fixture
          .backend
          .current
          .sessions
          .single
          .metadata!
          .mediaCommands
          .isEmpty,
    );
    final retained = fixture.backend.current.sessions.single;
    expect(fixture.backend.current.backendAvailable, isTrue);
    expect(retained.state, ProjectionSessionState.streaming);
    expect(
      retained.videoStreams.single.nativeViewParameters,
      original.videoStreams.single.nativeViewParameters,
    );
    expect(retained.metadata?.media, original.metadata?.media);
    expect(retained.metadata?.phone.batteryPercent, 61);
    expect(
      retained.metadata!.revision,
      greaterThan(original.metadata!.revision),
    );
    fixture.status['media'] = {..._media(), 'revision': 0, 'title': 'Stale'};
    fixture.status['media_commands'] = ['playPause'];
    await fixture.waitUntil(
      () => fixture
          .backend
          .current
          .sessions
          .single
          .metadata!
          .mediaCommands
          .isNotEmpty,
    );
    expect(
      fixture.backend.current.sessions.single.metadata?.media?.title,
      'Song',
    );
  });

  test('explicit clear, new track and replacement session never reuse old artwork or battery', () async {
    final fixture = await _MediaFixture.create();
    addTearDown(fixture.close);
    fixture.status['media'] = _media();
    fixture.status['phone'] = {'battery_percent': 61, 'external_power': true};
    await fixture.backend.start();
    final initial = fixture.backend.current.sessions.single.metadata!.revision;
    fixture.status['media'] = null;
    await fixture.waitUntil(
      () => fixture.backend.current.sessions.single.metadata!.media == null,
    );
    expect(
      fixture.backend.current.sessions.single.metadata!.revision,
      greaterThan(initial),
    );
    fixture.status['media'] = {
      'revision': 1,
      'updated_at_ms': 2000,
      'title': 'Next',
      'playback': 'paused',
      'artwork_path': '/etc/passwd',
    };
    await fixture.waitUntil(
      () =>
          fixture.backend.current.sessions.single.metadata?.media?.title ==
          'Next',
    );
    expect(
      fixture.backend.current.sessions.single.metadata?.media?.artworkPath,
      isNull,
    );
    expect(
      fixture.backend.current.sessions.single.metadata?.media?.artist,
      isNull,
    );
    fixture.replaceSession(8);
    fixture.status['media'] = {'revision': -1};
    fixture.status['phone'] = {'battery_percent': 'wrong'};
    await fixture.waitUntil(
      () => fixture.backend.current.sessions.single.id == '8',
    );
    final replacement = fixture.backend.current.sessions.single.metadata!;
    expect(replacement.media, isNull);
    expect(replacement.phone.batteryPercent, isNull);
    expect(replacement.phone.externalPower, isNull);
    expect(replacement.phone.charging, isNull);
    await expectLater(
      fixture.backend.sendButton(
        '7',
        ProjectionInputButton.playPause,
        pressed: true,
      ),
      throwsStateError,
    );
  });
}

String get _artworkPath {
  final root = Platform.environment['XDG_RUNTIME_DIR'];
  return '$root/argo-artwork-200-${List.filled(32, 'a').join()}/${List.filled(32, 'b').join()}.img';
}

Map<String, Object?> _media() => {
  'revision': 1,
  'updated_at_ms': 1000,
  'title': 'Song',
  'artist': 'Artist',
  'album': 'Album',
  'album_artist': 'Album artist',
  'genre': 'Genre',
  'application': 'Music',
  'application_id': 'com.example.player',
  'track_id': '0000000000000001',
  'playback': 'playing',
  'position_ms': 1200,
  'duration_ms': 123000,
  'artwork_path': _artworkPath,
};

class _MediaFixture {
  _MediaFixture(this.directory, this.server, this.backend, this.status);
  final Directory directory;
  final ServerSocket server;
  final CarPlayProjectionBackend backend;
  final Map<String, dynamic> status;
  final requests = <Map<String, dynamic>>[];
  final sockets = <Socket>[];
  StreamSubscription<Socket>? subscription;
  static Future<_MediaFixture> create({
    String? Function()? selectedMicrophone,
  }) async {
    final directory = await Directory.systemTemp.createTemp('carplay-media-');
    final path = '${directory.path}/control';
    final server = await ServerSocket.bind(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    final fixture = _MediaFixture(
      directory,
      server,
      CarPlayProjectionBackend(
        socketPath: path,
        selectedMicrophone: selectedMicrophone,
        pollInterval: const Duration(milliseconds: 50),
      ),
      {
        'contract': 1,
        'available': true,
        'session': 7,
        'device': 'fixture',
        'name': 'Fixture phone',
        'recorded': true,
        'selected': false,
        'visible': false,
        'audio': <Object>[],
      },
    );
    fixture.replaceSession(7);
    fixture.subscription = server.listen((socket) {
      fixture.sockets.add(socket);
      unawaited(fixture.handle(socket));
    });
    return fixture;
  }

  void replaceSession(int session) {
    status['session'] = session;
    final p = ByteData(40);
    p.buffer.asUint8List().setAll(0, [65, 82, 86, 50]);
    p.setUint32(4, 1);
    p.buffer.asUint8List().setAll(8, [2, 1, 1, 2, 2, 2]);
    p.setUint16(14, 1280);
    p.setUint16(16, 720);
    p.setUint16(18, 30);
    p.setUint16(20, 1);
    p.setUint64(24, session);
    status['video'] = {
      'width': 1280,
      'height': 720,
      'fps': 30,
      'codec': 'h264',
      'first_frame': true,
      'native_parameters': p.buffer.asUint8List().toList(),
    };
  }

  Future<void> handle(Socket socket) async {
    try {
      final line = await utf8.decoder
          .bind(socket)
          .transform(const LineSplitter())
          .first;
      final request = jsonDecode(line) as Map<String, dynamic>;
      requests.add(request);
      socket.writeln(
        jsonEncode(
          request['action'] == 'status'
              ? status
              : request['action'] == 'microphone_source' &&
                    status['microphone_mode'] == 'silence'
              ? {'ok': false, 'code': 'unsupported'}
              : {'ok': true},
        ),
      );
      await socket.flush();
      await socket.close();
    } on Object {
      /* Client shutdown also cancels an in-flight status request. */
    }
  }

  Future<void> waitUntil(bool Function() condition) async {
    if (condition()) return;
    await backend.changes
        .firstWhere((_) => condition())
        .timeout(const Duration(seconds: 3));
  }

  Future<void> close() async {
    await backend.close();
    for (final socket in sockets) {
      socket.destroy();
    }
    await subscription?.cancel();
    await server.close();
    await directory.delete(recursive: true);
  }
}
