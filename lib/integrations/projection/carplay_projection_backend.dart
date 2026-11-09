import '../../core/diagnostics/service_failure.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../core/projection/projection_backend.dart';
import 'projection_endpoints.dart';
import '../../core/projection/projection_models.dart';
import '../../core/projection/projection_types.dart';
import '../../core/media/media_state.dart';

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
  (String, String)? _metadataEpoch;
  int? _nativeMediaRevision;

  static const _mediaControls = {
    'previous',
    'play',
    'pause',
    'playPause',
    'next',
  };
  static int _integer(
    Object? value,
    String field, {
    int max = 0x7fffffffffffffff,
  }) {
    if (value is! int || value < 0 || value > max) {
      throw FormatException('Invalid CarPlay $field');
    }
    return value;
  }

  static int? _optionalInteger(
    Map<String, dynamic> data,
    String key, {
    int max = 0xffffffff,
  }) => data[key] == null ? null : _integer(data[key], key, max: max);
  static String? _text(Map<String, dynamic> data, String key) {
    final value = data[key];
    if (value == null) return null;
    if (value is! String ||
        value.length > 1024 ||
        RegExp(r'[\x00-\x1f]').hasMatch(value)) {
      throw FormatException('Invalid CarPlay $key');
    }
    return value.isEmpty ? null : value;
  }

  static bool? _boolean(Map<String, dynamic> data, String key) {
    final value = data[key];
    if (value == null || value is bool) return value as bool?;
    throw FormatException('Invalid CarPlay $key');
  }

  static String? _artwork(Map<String, dynamic> data) {
    final value = _text(data, 'artwork_path');
    final root = Platform.environment['XDG_RUNTIME_DIR'];
    if (value == null || root == null) return null;
    return RegExp(
          '^${RegExp.escape(root)}/argo-artwork-[0-9]+-[a-f0-9]{32}/[a-f0-9]{32}\\.img\$',
        ).hasMatch(value)
        ? value
        : null;
  }

  List<String> _commands(Map<String, dynamic> data) {
    final commands = data['media_commands'];
    if (data['recorded'] != true ||
        commands is! List ||
        commands.length > 5 ||
        commands.any((c) => c is! String || !_mediaControls.contains(c)) ||
        commands.toSet().length != commands.length) {
      return const [];
    }
    return List.unmodifiable(commands.cast<String>());
  }

  /// Optional Now Playing data cannot invalidate an authenticated video stream.
  /// Native revisions are checked within this exact phone/session epoch; the
  /// public revision also includes phone/capability updates and explicit clears.
  ProjectionSessionMetadata _metadata(
    Map<String, dynamic> data,
    String sessionId,
    ProjectionDevice device,
  ) {
    final epoch = (sessionId, device.id);
    final previous = epoch == _metadataEpoch
        ? _current.sessions
              .where((s) => s.id == sessionId && s.device.id == device.id)
              .firstOrNull
              ?.metadata
        : null;
    if (epoch != _metadataEpoch) {
      _metadataEpoch = epoch;
      _nativeMediaRevision = null;
    }
    var media = previous?.media;
    var received = previous?.updatedAtMs ?? 0;
    if (data.containsKey('media')) {
      if (data['media'] == null) {
        media = null;
        _nativeMediaRevision = null;
      } else {
        try {
          final block = data['media'];
          if (block is! Map<String, dynamic>) {
            throw const FormatException('Invalid CarPlay media');
          }
          final revision = _integer(block['revision'], 'media revision');
          final timestamp = _integer(block['updated_at_ms'], 'media timestamp');
          final parsed = MediaDetails(
            title: _text(block, 'title'),
            artist: _text(block, 'artist'),
            album: _text(block, 'album'),
            albumArtist: _text(block, 'album_artist'),
            genre: _text(block, 'genre'),
            application: _text(block, 'application'),
            applicationId: _text(block, 'application_id'),
            trackId: _text(block, 'track_id'),
            artworkPath: _artwork(block),
            playback: switch (block['playback']) {
              'playing' => MediaPlaybackState.playing,
              'paused' => MediaPlaybackState.paused,
              'stopped' => MediaPlaybackState.stopped,
              'seeking' => MediaPlaybackState.seeking,
              _ => MediaPlaybackState.unknown,
            },
            positionMs: _optionalInteger(block, 'position_ms'),
            durationMs: _optionalInteger(block, 'duration_ms'),
          );
          if (_nativeMediaRevision == null ||
              revision >= _nativeMediaRevision!) {
            media = parsed;
            received = timestamp;
            _nativeMediaRevision = revision;
          }
        } on Object {
          // Retain the preceding valid facts only for the same session/phone.
        }
      }
    }
    var phone =
        previous?.phone ?? PhoneDetails(displayName: device.displayName);
    if (data.containsKey('phone')) {
      try {
        final block = data['phone'];
        if (block == null) {
          phone = PhoneDetails(displayName: device.displayName);
        } else {
          if (block is! Map<String, dynamic>) {
            throw const FormatException('Invalid CarPlay phone');
          }
          phone = PhoneDetails(
            displayName: device.displayName,
            batteryPercent: _optionalInteger(
              block,
              'battery_percent',
              max: 100,
            ),
            charging: _boolean(block, 'charging'),
            externalPower: _boolean(block, 'external_power'),
          );
        }
      } on Object {
        /* Optional phone state cannot retire a valid stream. */
      }
    }
    final commands = _commands(data);
    final candidate = ProjectionSessionMetadata(
      revision: previous?.revision ?? 0,
      updatedAtMs: received,
      media: media,
      phone: phone,
      mediaCommands: commands,
    );
    if (candidate == previous) return previous!;
    return ProjectionSessionMetadata(
      revision: (previous?.revision ?? 0) + 1,
      updatedAtMs: received,
      media: media,
      phone: phone,
      mediaCommands: commands,
    );
  }

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
            if (response is! Map<String, dynamic>) {
              throw const FormatException('Invalid CarPlay response');
            }
            if (response['ok'] == false) {
              final code = response['code'];
              throw ServiceFailure(
                feature: 'carplay',
                operation: '${request['action']}',
                kind: switch (code) {
                  'stale_session' => FailureKind.staleSession,
                  'busy' => FailureKind.busy,
                  'unsupported' => FailureKind.unsupported,
                  _ => FailureKind.rejected,
                },
                summary: 'CarPlay rejected the request.',
                cause: response['error'] ?? 'No backend detail',
                retryable: code == 'busy',
                recovery: code == 'stale_session'
                    ? 'Reconnect the phone.'
                    : null,
              );
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
          // Silence and physical capture are negotiated for the session. A
          // newly plugged-in mic is saved for the next connection by settings;
          // switching this active route would reject the request and lose AV.
          data['microphone_mode'] != 'silence' &&
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
      final transport = switch (data['transport']) {
        null || 'usb' => ProjectionTransport.usb,
        'wireless' => ProjectionTransport.wifi,
        _ => throw const FormatException('Unknown CarPlay transport'),
      };
      final device = ProjectionDevice(
        id: deviceId,
        displayName: name,
        protocol: protocol,
        transport: transport,
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
        final metadata = ByteData.sublistView(
          Uint8List.fromList(parameters.cast<int>()),
        );
        final contentInsets = ProjectionInsets(
          left: metadata.getUint16(32).toDouble(),
          top: metadata.getUint16(34).toDouble(),
          right: metadata.getUint16(36).toDouble(),
          bottom: metadata.getUint16(38).toDouble(),
        );
        if (metadata.getUint32(0) != 0x41525632 ||
            metadata.getUint32(4) != 1 ||
            metadata.getUint16(14) != width ||
            metadata.getUint16(16) != height ||
            metadata.getUint64(24) != id ||
            contentInsets.left + contentInsets.right >= width ||
            contentInsets.top + contentInsets.bottom >= height) {
          throw const FormatException('Invalid CarPlay View Area');
        }
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
            contentInsets: contentInsets,
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
              phoneDucking: data['phone_duck'] is Map
                  ? ProjectionDucking(
                      (data['phone_duck']['gain'] as num).toDouble(),
                      data['phone_duck']['ramp_ms'] as int,
                    )
                  : null,
              metadata: _metadata(data, sessionId, device),
            ),
          ],
          activeSessionId: data['selected'] == true ? sessionId : null,
        ),
      );
    } on Object catch (error) {
      _nativeSession = null;
      _metadataEpoch = null;
      _nativeMediaRevision = null;
      final failure = error is ServiceFailure
          ? error
          : ServiceFailure(
              feature: 'carplay',
              operation: 'status',
              kind: error is TimeoutException
                  ? FailureKind.timeout
                  : error is SocketException
                  ? FailureKind.missingService
                  : error is FormatException
                  ? FailureKind.unsupported
                  : FailureKind.internal,
              summary: error is TimeoutException
                  ? 'CarPlay receiver did not respond in time.'
                  : error is SocketException
                  ? 'CarPlay receiver is not running or cannot be reached.'
                  : error is FormatException
                  ? 'CarPlay receiver returned an incompatible response.'
                  : 'Could not read CarPlay status.',
              cause: error,
              retryable: error is! FormatException,
              recovery: 'Check CarPlay settings and the receiver service.',
            );
      _publish(
        ProjectionSnapshot(
          backendAvailable: false,
          failureMessage: failure.summary,
          failure: failure,
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
    final command = switch (button) {
      ProjectionInputButton.playPause => 'playPause',
      ProjectionInputButton.next => 'next',
      ProjectionInputButton.previous => 'previous',
      ProjectionInputButton.play => 'play',
      ProjectionInputButton.pause => 'pause',
      _ => null,
    };
    if (command != null) {
      _session(sessionId);
      if (!pressed) return;
      final session = _current.sessions
          .where((s) => s.id == sessionId)
          .firstOrNull;
      if (session?.metadata?.mediaCommands.contains(command) != true) {
        throw UnsupportedError('CarPlay playback control is unavailable.');
      }
      await _command(sessionId, {'action': 'media', 'command': command});
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
