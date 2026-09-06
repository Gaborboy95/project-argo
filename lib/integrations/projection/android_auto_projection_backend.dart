import 'dart:async';

import '../../core/diagnostics/diagnostics_service.dart';
import '../../core/projection/projection_backend.dart';
import '../../core/projection/projection_models.dart';
import '../../core/projection/projection_preferences.dart';
import '../../core/projection/projection_types.dart';
import '../../core/projection/projection_configuration.dart';
import 'projection_ipc.dart';

final class AndroidAutoProjectionBackend
    implements ProjectionBackend, ProjectionConfigurationBackend {
  AndroidAutoProjectionBackend({
    required this.socketPath,
    required this.preferences,
    required this.diagnostics,
    ProjectionControlTransportFactory? transportFactory,
  }) : _transportFactory =
           transportFactory ?? UnixProjectionControlTransport.connect;

  final String socketPath;
  ProjectionPreferences preferences;
  ProjectionConfigurationState _configuration =
      const ProjectionConfigurationState();
  final _configurationChanges =
      StreamController<ProjectionConfigurationState>.broadcast(sync: true);
  int _revision = 0;
  bool _hello = false;
  @override
  ProjectionConfigurationState get configuration => _configuration;
  @override
  Stream<ProjectionConfigurationState> get configurationChanges =>
      _configurationChanges.stream;
  final DiagnosticsService diagnostics;
  final ProjectionControlTransportFactory _transportFactory;
  final StreamController<ProjectionSnapshot> _changes =
      StreamController<ProjectionSnapshot>.broadcast(sync: true);
  final Map<String, ProjectionDevice> _devices = {};
  final Map<String, ProjectionSession> _sessions = {};
  ProjectionControlTransport? _transport;
  StreamSubscription<ProjectionIpcMessage>? _subscription;
  ProjectionSnapshot _current = ProjectionSnapshot(backendAvailable: false);
  String? _activeSessionId;
  bool _closed = false;

  @override
  ProjectionProtocol get protocol => ProjectionProtocol.androidAuto;
  @override
  ProjectionSnapshot get current => _current;
  @override
  Stream<ProjectionSnapshot> get changes => _changes.stream;

  @override
  Future<void> start() async {
    if (_closed) throw StateError('Projection backend is closed.');
    try {
      final transport = await _transportFactory(socketPath);
      if (_closed) {
        await transport.close();
        return;
      }
      _transport = transport;
      _subscription = transport.messages.listen(
        _handleMessage,
        onError: (Object error, StackTrace stackTrace) {
          _fail(
            'Projection sidecar protocol failed: $error',
            error,
            stackTrace,
          );
        },
        onDone: () {
          if (!_closed && (_hello || _current.failureMessage == null)) {
            _fail('Projection sidecar disconnected.');
          }
        },
      );
      await transport.send(const ProjectionIpcMessage(ProjectionIpcKind.hello));
    } on Object catch (error, stackTrace) {
      _fail(
        'Could not connect to Android Auto projection sidecar at "$socketPath".',
        error,
        stackTrace,
      );
    }
  }

  void _handleMessage(ProjectionIpcMessage message) {
    try {
      final reader = ProjectionIpcReader(message.payload);
      switch (message.kind) {
        case ProjectionIpcKind.hello:
          if (!reader.isDone) throw const FormatException('Malformed hello.');
          _hello = true;
          return;
        case ProjectionIpcKind.capabilities:
          _handleCapabilities(reader);
          unawaited(
            requestConfiguration(preferences)
                .catchError((Object error, StackTrace stack) {
                  _fail('Could not send projection preferences.', error, stack);
                }),
          );
          return;
        case ProjectionIpcKind.configuration:
          _handleConfiguration(reader);
          return;
        case ProjectionIpcKind.configure:
          throw const FormatException(
            'Daemon sent client configuration request.',
          );
        case ProjectionIpcKind.device:
          final device = ProjectionDevice(
            id: reader.string(),
            displayName: reader.string(),
            protocol: _enumAt(ProjectionProtocol.values, reader.uint8()),
            transport: _enumAt(ProjectionTransport.values, reader.uint8()),
          );
          _requireDone(reader);
          _devices[device.id] = device;
          _publish();
          return;
        case ProjectionIpcKind.deviceRemoved:
          _devices.remove(reader.string());
          _requireDone(reader);
          _publish();
          return;
        case ProjectionIpcKind.session:
          final id = reader.string();
          final deviceId = reader.string();
          final state = _enumAt(ProjectionSessionState.values, reader.uint8());
          final failure = reader.string();
          _requireDone(reader);
          final device = _devices[deviceId];
          if (device == null) {
            throw FormatException(
              'Session references unknown device "$deviceId".',
            );
          }
          final previous = _sessions[id];
          _sessions[id] = ProjectionSession(
            id: id,
            device: device,
            state: state,
            videoStreams: previous?.videoStreams ?? const [],
            audioStreams: previous?.audioStreams ?? const [],
            failureMessage: failure.isEmpty ? null : failure,
          );
          _publish();
          return;
        case ProjectionIpcKind.sessionRemoved:
          final removed = reader.string();
          _requireDone(reader);
          _sessions.remove(removed);
          if (_activeSessionId == removed) _activeSessionId = null;
          _publish();
          return;
        case ProjectionIpcKind.videoStream:
          _handleVideoStream(reader);
          return;
        case ProjectionIpcKind.audioStream:
          _handleAudioStream(reader);
          return;
        case ProjectionIpcKind.error:
          final message = reader.string();
          _requireDone(reader);
          _fail(message);
          return;
        case ProjectionIpcKind.connect ||
            ProjectionIpcKind.disconnect ||
            ProjectionIpcKind.activate ||
            ProjectionIpcKind.touch ||
            ProjectionIpcKind.button ||
            ProjectionIpcKind.rotary ||
            ProjectionIpcKind.videoVisibility ||
            ProjectionIpcKind.audioGain:
          throw FormatException(
            'Sidecar sent command-only message ${message.kind.name}.',
          );
      }
    } on Object catch (error, stackTrace) {
      _fail('Malformed projection IPC message: $error', error, stackTrace);
    }
  }

  ProjectionPreferences _readPreferences(ProjectionIpcReader r) {
    final width = r.uint16(),
        height = r.uint16(),
        dpi = r.uint16(),
        fps = r.uint8(),
        side = r.uint8();
    if (side > 1) throw const FormatException('Invalid driver side');
    return ProjectionPreferences(
      width: width,
      height: height,
      dpi: dpi,
      framesPerSecond: fps,
      driverSide: ProjectionDriverSide.values[side],
      safeInsets: const ProjectionInsets(),
    );
  }

  void _handleCapabilities(ProjectionIpcReader r) {
    if (!_hello) throw const FormatException('Capabilities before hello');
    final status = r.uint8();
    if (status > 3) throw const FormatException('Unknown readiness');
    final detail = r.string();
    final resolutions = <(int, int)>[];
    final count = r.uint8();
    for (var i = 0; i < count; i++) {
      resolutions.add((r.uint16(), r.uint16()));
    }
    final fps = <int>[];
    final fpsCount = r.uint8();
    for (var i = 0; i < fpsCount; i++) {
      fps.add(r.uint8());
    }
    final minimum = r.uint16(), maximum = r.uint16();
    final defaults = _readPreferences(r);
    final audio = <ProjectionAudioFormat>[];
    final audioCount = r.uint8();
    for (var i = 0; i < audioCount; i++) {
      final role = r.uint8();
      if (role > 2) throw const FormatException('Invalid audio role');
      audio.add(
        ProjectionAudioFormat(
          ['Media', 'Speech/navigation', 'System'][role],
          r.uint16(),
          r.uint8(),
          r.uint8(),
        ),
      );
    }
    _requireDone(r);
    final caps = ProjectionCapabilities(
      resolutions: resolutions,
      frameRates: fps,
      minimumDpi: minimum,
      maximumDpi: maximum,
      defaults: defaults,
      audio: audio,
    );
    if (!caps.supports(defaults)) {
      throw const FormatException('Invalid capability defaults');
    }
    _configuration = ProjectionConfigurationState(
      readiness: ProjectionReadiness.values[status + 1],
      message: detail,
      capabilities: caps,
    );
    _configurationChanges.add(_configuration);
    _publish(
      backendAvailable: status == 0,
      failureMessage: status == 0 ? null : detail,
    );
  }

  void _handleConfiguration(ProjectionIpcReader r) {
    final revision = r.uint32();
    final accepted = r.uint8();
    final reason = r.string();
    final pending = _readPreferences(r);
    final id = r.string();
    final active = id.isEmpty ? null : _readPreferences(r);
    _requireDone(r);
    if (accepted > 1) {
      throw const FormatException('Invalid configuration acknowledgement');
    }
    // Initial session snapshot is authoritative even while our first request is in flight.
    if (revision < _configuration.revision ||
        (revision != 0 && revision < _revision)) {
      return;
    }
    _configuration = ProjectionConfigurationState(
      readiness: _configuration.readiness,
      message: _configuration.message,
      capabilities: _configuration.capabilities,
      pending: pending,
      active: active,
      sessionId: id.isEmpty ? null : id,
      revision: revision,
      accepted: accepted == 1,
      rejection: reason.isEmpty ? null : reason,
    );
    _configurationChanges.add(_configuration);
  }

  @override
  Future<void> requestConfiguration(ProjectionPreferences value) async {
    preferences = value;
    if (!_hello || _transport == null || _closed) {
      throw StateError('Projection control unavailable');
    }
    final w = ProjectionIpcWriter()
      ..uint32(++_revision)
      ..uint16(value.width)
      ..uint16(value.height)
      ..uint16(value.dpi)
      ..uint8(value.framesPerSecond)
      ..uint8(value.driverSide.index);
    await _transport!.send(
      ProjectionIpcMessage(ProjectionIpcKind.configure, w.takeBytes()),
    );
  }

  void _handleVideoStream(ProjectionIpcReader reader) {
    final sessionId = reader.string();
    final session = _sessions[sessionId];
    if (session == null) {
      throw FormatException('Video stream references unknown session.');
    }
    final stream = ProjectionVideoStream(
      id: reader.string(),
      sessionId: sessionId,
      role: _enumAt(ProjectionVideoRole.values, reader.uint8()),
      codec: _enumAt(ProjectionVideoCodec.values, reader.uint8()),
      width: reader.uint16(),
      height: reader.uint16(),
      framesPerSecond: reader.uint8(),
      contentInsets: ProjectionInsets(
        left: reader.uint16().toDouble(),
        top: reader.uint16().toDouble(),
        right: reader.uint16().toDouble(),
        bottom: reader.uint16().toDouble(),
      ),
      safeInsets: ProjectionInsets(
        left: reader.uint16().toDouble(),
        top: reader.uint16().toDouble(),
        right: reader.uint16().toDouble(),
        bottom: reader.uint16().toDouble(),
      ),
      visible: reader.uint8() != 0,
      focused: reader.uint8() != 0,
    );
    _requireDone(reader);
    final streams = [
      for (final current in session.videoStreams)
        if (current.id != stream.id) current,
      stream,
    ];
    _sessions[sessionId] = ProjectionSession(
      id: session.id,
      device: session.device,
      state: session.state,
      videoStreams: streams,
      audioStreams: session.audioStreams,
      failureMessage: session.failureMessage,
    );
    _publish();
  }

  void _handleAudioStream(ProjectionIpcReader reader) {
    final sessionId = reader.string();
    final session = _sessions[sessionId];
    if (session == null) {
      throw FormatException('Audio stream references unknown session.');
    }
    final stream = ProjectionAudioStream(
      id: reader.string(),
      sessionId: sessionId,
      role: _enumAt(ProjectionAudioRole.values, reader.uint8()),
      active: reader.uint8() != 0,
      hasFocus: reader.uint8() != 0,
      sampleRate: reader.uint16(),
      bitsPerSample: reader.uint8(),
      channelCount: reader.uint8(),
    );
    _requireDone(reader);
    final streams = [
      for (final current in session.audioStreams)
        if (current.id != stream.id) current,
      stream,
    ];
    _sessions[sessionId] = ProjectionSession(
      id: session.id,
      device: session.device,
      state: session.state,
      videoStreams: session.videoStreams,
      audioStreams: streams,
      failureMessage: session.failureMessage,
    );
    _publish();
  }

  static T _enumAt<T>(List<T> values, int index) {
    if (index >= values.length) {
      throw FormatException('Unknown projection enum value $index.');
    }
    return values[index];
  }

  static void _requireDone(ProjectionIpcReader reader) {
    if (!reader.isDone) {
      throw const FormatException('Trailing IPC payload data.');
    }
  }

  void _publish({bool? backendAvailable, String? failureMessage}) {
    final next = ProjectionSnapshot(
      backendAvailable: backendAvailable ?? _current.backendAvailable,
      devices: _devices.values,
      sessions: _sessions.values,
      activeSessionId: _activeSessionId,
      failureMessage:
          failureMessage ??
          ((backendAvailable ?? _current.backendAvailable)
              ? null
              : _configuration.message),
    );
    if (next == _current) return;
    _current = next;
    _changes.add(next);
  }

  void _fail(String message, [Object? error, StackTrace? stackTrace]) {
    if (_closed) return;
    _hello = false;
    _configuration = ProjectionConfigurationState(message: message);
    _configurationChanges.add(_configuration);
    _devices.clear();
    _sessions.clear();
    _activeSessionId = null;
    diagnostics.error(
      'projection.androidAuto',
      message,
      error: error,
      stackTrace: stackTrace,
    );
    _publish(backendAvailable: false, failureMessage: message);
  }

  Future<void> _send(ProjectionIpcKind kind, ProjectionIpcWriter writer) async {
    if (_closed) throw StateError('Projection backend is closed.');
    final transport = _transport;
    if (transport == null || !_current.backendAvailable) {
      throw StateError('Projection sidecar is unavailable.');
    }
    await transport.send(ProjectionIpcMessage(kind, writer.takeBytes()));
  }

  @override
  Future<void> connect(String deviceId) =>
      _send(ProjectionIpcKind.connect, ProjectionIpcWriter()..string(deviceId));

  @override
  Future<void> disconnect(String sessionId) => _send(
    ProjectionIpcKind.disconnect,
    ProjectionIpcWriter()..string(sessionId),
  );

  @override
  Future<void> activate(String sessionId) async {
    await _send(
      ProjectionIpcKind.activate,
      ProjectionIpcWriter()..string(sessionId),
    );
    _activeSessionId = sessionId;
    _publish();
  }

  @override
  Future<void> sendTouch(String sessionId, ProjectionTouch touch) => _send(
    ProjectionIpcKind.touch,
    ProjectionIpcWriter()
      ..string(sessionId)
      ..uint16(touch.pointerId)
      ..uint8(touch.phase.index)
      ..float32(touch.x)
      ..float32(touch.y),
  );

  @override
  Future<void> sendButton(
    String sessionId,
    ProjectionInputButton button, {
    required bool pressed,
  }) => _send(
    ProjectionIpcKind.button,
    ProjectionIpcWriter()
      ..string(sessionId)
      ..uint8(button.index)
      ..uint8(pressed ? 1 : 0),
  );

  @override
  Future<void> sendRotary(String sessionId, int detents) => _send(
    ProjectionIpcKind.rotary,
    ProjectionIpcWriter()
      ..string(sessionId)
      ..int16(detents),
  );

  @override
  Future<void> setVideoVisibility(String streamId, bool visible) => _send(
    ProjectionIpcKind.videoVisibility,
    ProjectionIpcWriter()
      ..string(streamId)
      ..uint8(visible ? 1 : 0),
  );

  @override
  Future<void> setAudioGain(String sessionId, String streamId, double gain) {
    if (!gain.isFinite || gain < 0 || gain > 1) {
      return Future.error(RangeError.range(gain, 0, 1, 'gain'));
    }
    return _send(
      ProjectionIpcKind.audioGain,
      ProjectionIpcWriter()
        ..string(sessionId)
        ..string(streamId)
        ..float32(gain),
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription?.cancel();
    await _transport?.close();
    await _configurationChanges.close();
    await _changes.close();
  }
}
