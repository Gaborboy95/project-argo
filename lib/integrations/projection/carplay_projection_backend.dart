import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/projection/projection_backend.dart';
import 'projection_endpoints.dart';
import '../../core/projection/projection_models.dart';
import '../../core/projection/projection_types.dart';

/// Metadata and input only. The native daemon owns USB, authentication and AV.
final class CarPlayProjectionBackend implements ProjectionBackend {
  CarPlayProjectionBackend({
    required this.socketPath,
    this.microphoneMuted,
    this.selectedMicrophone,
    this.pollInterval = const Duration(milliseconds: 500),
  }) {
    projectionEndpoint(
      {'socket': socketPath},
      'socket',
      'carplay-control.sock',
    );
    if (pollInterval < const Duration(milliseconds: 50)) {
      throw ArgumentError.value(pollInterval, 'pollInterval');
    }
  }
  final String socketPath;
  final bool Function()? microphoneMuted;
  final String? Function()? selectedMicrophone;
  (int, String)? _sentMicrophoneSource;
  (int, bool)? _sentMicrophonePolicy;
  final Duration pollInterval;
  final _changes = StreamController<ProjectionSnapshot>.broadcast(sync: true);
  final Set<Socket> _sockets = {};
  ProjectionSnapshot _current = const ProjectionSnapshot.disabled();
  Timer? _timer;
  bool _started = false, _closed = false;
  Future<void>? _polling;
  int? _nativeSession;

  @override
  ProjectionProtocol get protocol => ProjectionProtocol.carPlay;
  @override
  ProjectionSnapshot get current => _current;
  @override
  Stream<ProjectionSnapshot> get changes => _changes.stream;

  Future<Map<String, dynamic>> _request(Map<String, Object?> request) async {
    if (_closed) throw StateError('CarPlay backend is closed');
    Socket? socket;
    try {
      return await (() async {
        socket = await Socket.connect(
          InternetAddress(socketPath, type: InternetAddressType.unix),
          0,
          timeout: const Duration(seconds: 2),
        );
        if (_closed) throw StateError('CarPlay backend is closed');
        final connection = socket!;
        _sockets.add(connection);
        connection.write('${jsonEncode(request)}\n');
        final bytes = <int>[];
        await for (final chunk in connection) {
          final end = chunk.indexOf(10);
          final part = end < 0 ? chunk : chunk.sublist(0, end);
          if (bytes.length + part.length > 16384) {
            throw const FormatException('CarPlay response bounds');
          }
          bytes.addAll(part);
          if (end >= 0) {
            final response = jsonDecode(utf8.decode(bytes));
            if (response is! Map<String, dynamic> || response['ok'] == false) {
              throw const FormatException('CarPlay operation unavailable');
            }
            return response;
          }
        }
        throw const FormatException('Incomplete CarPlay response');
      })().timeout(const Duration(seconds: 2));
    } finally {
      _sockets.remove(socket);
      socket?.destroy();
    }
  }

  void _publish(ProjectionSnapshot next) {
    if (_closed || next == _current) return;
    _current = next;
    _changes.add(next);
  }

  Future<void> _poll() => _polling ??= _refresh().whenComplete(() {
    _polling = null;
    if (!_closed) _timer = Timer(pollInterval, _poll);
  });

  Future<void> _refresh() async {
    try {
      final data = await _request({'action': 'status'});
      final mutePolicy = microphoneMuted;
      final policySession = data['session'];
      if (mutePolicy != null &&
          policySession is int &&
          data['available'] == true &&
          data['contract'] == 1 &&
          data['microphone_policy'] == true) {
        final policy = (policySession, mutePolicy());
        if (_sentMicrophonePolicy != policy) {
          await _request({
            'action': 'microphone_mute',
            'session': policy.$1,
            'muted': policy.$2,
          });
          _sentMicrophonePolicy = policy;
        }
      }

      final source = selectedMicrophone?.call();
      if (policySession is int &&
          data['available'] == true &&
          data['microphone_source'] == true &&
          source != null &&
          source.isNotEmpty) {
        final selection = (policySession, source);
        if (_sentMicrophoneSource != selection) {
          await _request({
            'action': 'microphone_source',
            'session': policySession,
            'source': source,
          });
          _sentMicrophoneSource = selection;
        }
      }
      if (data['contract'] != 1 || data['available'] != true) {
        throw const FormatException('Unsupported CarPlay contract');
      }
      final id = data['session'];
      final deviceId = data['device'];
      final name = data['name'];
      if (id is! int ||
          id <= 0 ||
          deviceId is! String ||
          deviceId.length > 128 ||
          name is! String ||
          name.length > 128) {
        throw const FormatException('Invalid CarPlay identity');
      }
      _nativeSession = id;
      final sessionId = '$id';
      final device = ProjectionDevice(
        id: deviceId,
        displayName: name,
        protocol: protocol,
        transport: ProjectionTransport.usb,
      );
      final videos = <ProjectionVideoStream>[];
      var receivedFrame = false;
      if (data['video'] case final Map<String, dynamic> video) {
        final width = video['width'],
            height = video['height'],
            fps = video['fps'];
        final parameters = video['native_parameters'];
        if (width is! int ||
            width < 1 ||
            width > 1920 ||
            height is! int ||
            height < 1 ||
            height > 1080 ||
            fps is! int ||
            fps < 1 ||
            fps > 60 ||
            parameters is! List ||
            parameters.length != 40 ||
            parameters.any((v) => v is! int || v < 0 || v > 255)) {
          throw const FormatException(
            'Invalid native CarPlay video descriptor',
          );
        }
        if (parameters[8] != 2 || parameters[9] != 1) {
          throw const FormatException('Invalid CarPlay video plane');
        }
        final codec = switch (video['codec']) {
          'h264' => ProjectionVideoCodec.h264,
          'hevc' => ProjectionVideoCodec.hevc,
          _ => throw const FormatException('Unsupported CarPlay codec'),
        };
        receivedFrame = video['first_frame'] == true;
        videos.add(
          ProjectionVideoStream(
            id: 'main',
            sessionId: sessionId,
            role: ProjectionVideoRole.main,
            codec: codec,
            width: width,
            height: height,
            framesPerSecond: fps,
            nativeViewParameters: parameters.cast<int>(),
            presentationRevision: video['presentation_revision'] as int? ?? 0,
            visible: data['visible'] == true,
            focused: data['selected'] == true,
          ),
        );
      }
      final audio = <ProjectionAudioStream>[];
      final streams = data['audio'];
      if (streams is! List || streams.length > 4) {
        throw const FormatException('Invalid CarPlay audio list');
      }
      for (final stream in streams) {
        if (stream is! Map ||
            stream['connection'] is! String ||
            (stream['connection'] as String).length > 20 ||
            stream['rate'] is! int ||
            stream['channels'] is! int ||
            (stream['rate'] as int) < 8000 ||
            (stream['rate'] as int) > 48000 ||
            (stream['channels'] as int) < 1 ||
            (stream['channels'] as int) > 2) {
          throw const FormatException('Invalid CarPlay audio');
        }
        audio.add(
          ProjectionAudioStream(
            id: stream['connection'] as String,
            sessionId: sessionId,
            role: switch (stream['category']) {
              'media' => ProjectionAudioRole.media,
              'telephony' => ProjectionAudioRole.communication,
              'speechRecognition' => ProjectionAudioRole.speech,
              _ => ProjectionAudioRole.system,
            },
            active: stream['active'] == true,
            hasFocus: data['selected'] == true,
            sampleRate: stream['rate'] as int,
            bitsPerSample: 16,
            channelCount: stream['channels'] as int,
          ),
        );
      }
      _publish(
        ProjectionSnapshot(
          backendAvailable: true,
          devices: [device],
          sessions: [
            ProjectionSession(
              id: sessionId,
              device: device,
              state: receivedFrame
                  ? ProjectionSessionState.streaming
                  : data['recorded'] == true
                  ? ProjectionSessionState.ready
                  : ProjectionSessionState.connecting,
              videoStreams: videos,
              audioStreams: audio,
              hostReturnRevision: data['host_return_revision'] as int? ?? 0,
            ),
          ],
          activeSessionId: data['selected'] == true ? sessionId : null,
        ),
      );
    } on Object {
      _nativeSession = null;
      _publish(
        ProjectionSnapshot(
          backendAvailable: false,
          failureMessage: 'CarPlay receiver unavailable.',
        ),
      );
    }
  }

  @override
  Future<void> start() async {
    if (_closed) throw StateError('CarPlay backend is closed');
    if (_started) return;
    _started = true;
    await _poll();
  }

  int _session(String sessionId) {
    if (sessionId != '${_nativeSession ?? ''}') {
      throw StateError('CarPlay session is no longer current');
    }
    return _nativeSession!;
  }

  Future<void> _command(String sessionId, Map<String, Object?> body) async {
    await _request({...body, 'session': _session(sessionId)});
  }

  @override
  Future<void> connect(String deviceId) async {
    if (!_current.devices.any((d) => d.id == deviceId)) {
      throw StateError('Unknown CarPlay device');
    }
    await activate('${_nativeSession!}');
  }

  @override
  Future<void> activate(String sessionId) async {
    await _command(sessionId, {'action': 'activate'});
    await _refresh();
  }

  @override
  Future<void> disconnect(String sessionId) async {
    await _command(sessionId, {'action': 'disconnect'});
    await _refresh();
  }

  @override
  Future<void> sendTouch(String sessionId, ProjectionTouch touch) async {
    touch.validate();
    await _command(sessionId, {
      'action': 'touch',
      'pointer': touch.pointerId,
      'phase': touch.phase.name,
      'x': touch.x,
      'y': touch.y,
    });
  }

  @override
  Future<void> sendButton(
    String sessionId,
    ProjectionInputButton button, {
    required bool pressed,
  }) async {
    if (button == ProjectionInputButton.voiceAssistant) {
      await _command(sessionId, {'action': 'siri', 'pressed': pressed});
      return;
    }
    throw UnsupportedError('CarPlay does not support ${button.name} input.');
  }

  @override
  Future<void> sendRotary(String sessionId, int detents) async {
    throw UnsupportedError('CarPlay rotary input is not available.');
  }

  @override
  Future<void> setVideoVisibility(String streamId, bool visible) async {
    if (streamId != 'main' || _nativeSession == null) return;
    await _command('$_nativeSession', {
      'action': 'visibility',
      'visible': visible,
    });
  }

  @override
  Future<void> setAudioGain(
    String sessionId,
    String streamId,
    double gain,
  ) async {
    if (!gain.isFinite || gain < 0 || gain > 1) {
      throw ArgumentError.value(gain, 'gain');
    }
    await _command(sessionId, {
      'action': 'gain',
      'connection': streamId,
      'gain': gain,
    });
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
    await _polling;
    await _changes.close();
  }
}
