import 'dart:async';
import 'dart:convert';

import 'projection_backend.dart';
import 'projection_models.dart';
import 'projection_types.dart';

/// Combines independent protocol adapters without granting presentation from
/// incoming video/focus updates. This class owns and closes its adapters.
///
/// IDs are opaque, protocol-qualified values. Native media endpoints must still
/// be selected independently using a validated native stream descriptor; an ID
/// here is not a path, native view ID, or encoded-media subscription.
final class MultiplexProjectionBackend implements ProjectionBackend {
  MultiplexProjectionBackend(Iterable<ProjectionBackend> backends)
    : _backends = List.unmodifiable(backends) {
    final protocols = <ProjectionProtocol>{};
    for (final backend in _backends) {
      if (backend.protocol == null || !protocols.add(backend.protocol!)) {
        throw ArgumentError('Each adapter must have a distinct protocol.');
      }
    }
    if (_backends.isEmpty) {
      throw ArgumentError('At least one projection adapter is required.');
    }
  }

  final List<ProjectionBackend> _backends;
  final Map<ProjectionBackend, ProjectionSnapshot> _snapshots = {};
  final List<StreamSubscription<ProjectionSnapshot>> _subscriptions = [];
  final _changes = StreamController<ProjectionSnapshot>.broadcast(sync: true);
  final Map<String, (ProjectionBackend, String)> _devices = {};
  final Map<String, (ProjectionBackend, ProjectionSession)> _sessions = {};
  final Map<String, (ProjectionBackend, String, String)> _video = {};
  final Map<String, (ProjectionBackend, String, String)> _audio = {};
  final Set<String> _hiddenStreams = {};
  final Set<String> _hiddenMainSessions = {};
  final Map<String, (int, bool)> _identities = {};
  int _nextIdentity = 0;
  ProjectionSnapshot _current = const ProjectionSnapshot.disabled();
  Future<void> _commandTail = Future<void>.value();
  Future<void>? _start;
  Future<void>? _closing;
  String? _owner;
  ProjectionBackend? _preferredBackend;
  bool _closed = false;

  @override
  ProjectionProtocol? get protocol => null;
  @override
  ProjectionSnapshot get current => _current;
  @override
  Stream<ProjectionSnapshot> get changes => _changes.stream;

  @override
  Future<void> start() {
    _requireOpen();
    return _start ??= _startAdapters();
  }

  Future<void> _startAdapters() async {
    for (final backend in _backends) {
      _subscriptions.add(
        backend.changes.listen(
          (snapshot) {
            if (_closed) return;
            _snapshots[backend] = snapshot;
            _publish();
          },
          onError: (Object error) => _failed(backend),
          onDone: () => _failed(backend),
        ),
      );
    }
    await Future.wait(
      _backends.map((backend) async {
        try {
          await backend.start();
          if (!_closed) _snapshots[backend] = backend.current;
        } on Object {
          // A failed protocol adapter must not prevent another from starting.
          _failed(backend);
          try {
            await backend.close();
          } on Object {
            // The failed adapter remains unavailable even if cleanup fails.
          }
        }
      }),
    );
    if (!_closed) _publish();
  }

  void _failed(ProjectionBackend backend) {
    if (_closed) return;
    _snapshots[backend] = ProjectionSnapshot(
      backendAvailable: false,
      failureMessage: '${backend.protocol!.name} backend unavailable.',
    );
    _publish();
  }

  void _publish() {
    _devices.clear();
    _sessions.clear();
    _video.clear();
    _audio.clear();
    final devices = <ProjectionDevice>[];
    final sessions = <ProjectionSession>[];
    final present = <String>{};
    for (final backend in _backends) {
      final snapshot = _snapshots[backend];
      if (snapshot == null || !snapshot.backendAvailable) continue;
      for (final device in snapshot.devices) {
        final id = _id(backend, 'device', device.id);
        _devices[id] = (backend, device.id);
        devices.add(_wrapDevice(backend, device));
      }
      for (final session in snapshot.sessions) {
        final key = _id(backend, 'session', session.id);
        final live =
            session.state != ProjectionSessionState.failed &&
            session.state != ProjectionSessionState.disconnected;
        final previous = _identities[key];
        _identities[key] = (
          previous == null || (!previous.$2 && live)
              ? ++_nextIdentity
              : previous.$1,
          live,
        );
        present.add(key);
        final id = _sessionId(backend, session.id);
        _sessions[id] = (backend, session);
      }
    }

    _identities.removeWhere((key, _) => !present.contains(key));
    if (!_isLive(_owner)) _owner = null;
    // The first connected adapter supplies the initial selection. Thereafter,
    // reconnection may restore that same adapter, but another protocol must be
    // selected explicitly. Incoming frames never steal an existing owner.
    if (_owner == null) {
      for (final backend in _backends) {
        if (_preferredBackend != null && _preferredBackend != backend) continue;
        final local = _snapshots[backend]?.activeSessionId;
        if (local == null) continue;
        final candidate = _sessionId(backend, local);
        if (!_isLive(candidate)) continue;
        _preferredBackend = backend;
        _owner = candidate;
        break;
      }
    }
    for (final entry in _sessions.entries) {
      final (backend, session) = entry.value;
      sessions.add(_wrapSession(backend, session, entry.key));
    }
    _hiddenStreams.removeWhere((id) => !_video.containsKey(id));
    _hiddenMainSessions.removeWhere((id) => !_sessions.containsKey(id));
    final available = _snapshots.values.any((s) => s.backendAvailable);
    final next = ProjectionSnapshot(
      backendAvailable: available,
      devices: devices,
      sessions: sessions,
      activeSessionId: _owner,
      failureMessage: available ? null : 'Projection backends unavailable.',
    );
    if (next == _current) return;
    _current = next;
    _changes.add(next);
  }

  bool _isLive(String? id) {
    final session = _sessions[id]?.$2;
    return session != null &&
        session.state != ProjectionSessionState.failed &&
        session.state != ProjectionSessionState.disconnected;
  }

  ProjectionDevice _wrapDevice(ProjectionBackend backend, ProjectionDevice d) =>
      ProjectionDevice(
        id: _id(backend, 'device', d.id),
        displayName: d.displayName,
        protocol: backend.protocol!,
        transport: d.transport,
      );

  ProjectionSession _wrapSession(
    ProjectionBackend backend,
    ProjectionSession session,
    String id,
  ) => ProjectionSession(
    id: id,
    device: _wrapDevice(backend, session.device),
    state: session.state,
    failureMessage: session.failureMessage,
    hostReturnRevision: session.hostReturnRevision,
    metadata: session.metadata,
    videoStreams: session.videoStreams.map((stream) {
      final streamId = _streamId(backend, 'video', session.id, stream.id);
      _video[streamId] = (backend, session.id, stream.id);
      final selected =
          id == _owner &&
          !_hiddenStreams.contains(streamId) &&
          !(stream.role == ProjectionVideoRole.main &&
              _hiddenMainSessions.contains(id));
      return ProjectionVideoStream(
        id: streamId,
        sessionId: id,
        role: stream.role,
        codec: stream.codec,
        width: stream.width,
        height: stream.height,
        framesPerSecond: stream.framesPerSecond,
        contentInsets: stream.contentInsets,
        safeInsets: stream.safeInsets,
        visible: selected && stream.visible,
        focused: selected && stream.focused,
        presentationRevision: stream.presentationRevision,
        nativeViewParameters: stream.nativeViewParameters,
      );
    }),
    audioStreams: session.audioStreams.map((stream) {
      final streamId = _streamId(backend, 'audio', session.id, stream.id);
      _audio[streamId] = (backend, session.id, stream.id);
      return ProjectionAudioStream(
        id: streamId,
        sessionId: id,
        role: stream.role,
        active: stream.active,
        hasFocus: stream.hasFocus,
        sampleRate: stream.sampleRate,
        bitsPerSample: stream.bitsPerSample,
        channelCount: stream.channelCount,
      );
    }),
  );

  @override
  Future<void> connect(String deviceId) async {
    _requireOpen();
    final route = _devices[deviceId];
    if (route == null) throw StateError('Unknown projection device.');
    await route.$1.connect(route.$2);
  }

  @override
  Future<void> disconnect(String sessionId) => _enqueue(() async {
    final (backend, session) = _session(sessionId);
    await backend.disconnect(session.id);
  });

  @override
  Future<void> activate(String sessionId) => _enqueue(() async {
    final (backend, session) = _session(sessionId);
    final previous = _owner;
    if (previous != sessionId && previous != null) {
      final prior = _sessions[previous];
      if (prior != null) {
        _hiddenMainSessions.add(previous);
        for (final stream in prior.$2.videoStreams) {
          if (stream.role != ProjectionVideoRole.main) continue;
          _hiddenStreams.add(
            _streamId(prior.$1, 'video', prior.$2.id, stream.id),
          );
          _publish();
          await prior.$1.setVideoVisibility(stream.id, false);
        }
      }
    }
    await backend.activate(session.id);
    _requireOpen();
    if (!_isLive(sessionId)) {
      throw StateError('Projection session ended during activation.');
    }
    _preferredBackend = backend;
    _owner = sessionId;
    _hiddenMainSessions.remove(sessionId);
    for (final stream in session.videoStreams) {
      _hiddenStreams.remove(_streamId(backend, 'video', session.id, stream.id));
    }
    _publish();
  });

  @override
  Future<void> setVideoVisibility(String streamId, bool visible) =>
      _enqueue(() async {
        final route = _video[streamId];
        if (route == null) throw StateError('Unknown projection video stream.');
        final (backend, session, stream) = route;
        if (visible && _owner != _sessionId(backend, session)) {
          throw StateError('Only the selected session may become visible.');
        }
        final sessionId = _sessionId(backend, session);
        final main =
            _sessions[sessionId]?.$2.videoStreams.any(
              (s) => s.id == stream && s.role == ProjectionVideoRole.main,
            ) ??
            false;
        if (!visible) {
          if (main) _hiddenMainSessions.add(sessionId);
          _hiddenStreams.add(streamId);
          _publish();
        }
        await backend.setVideoVisibility(stream, visible);
        if (visible) {
          if (main) _hiddenMainSessions.remove(sessionId);
          _hiddenStreams.remove(streamId);
          _publish();
        }
      });

  @override
  Future<void> sendTouch(String sessionId, ProjectionTouch touch) async {
    touch.validate();
    final (backend, session) = _session(sessionId);
    // Terminal events belong to the originating session even if a local switch
    // hid it while an accepted gesture was being cancelled by the view.
    if (touch.phase != ProjectionTouchPhase.cancel &&
        touch.phase != ProjectionTouchPhase.up) {
      _requireInputOwner(sessionId);
    }
    await backend.sendTouch(session.id, touch);
  }

  @override
  Future<void> sendButton(
    String sessionId,
    ProjectionInputButton button, {
    required bool pressed,
  }) async {
    final (backend, session) = _session(sessionId);
    if (pressed) _requireInputOwner(sessionId);
    await backend.sendButton(session.id, button, pressed: pressed);
  }

  @override
  Future<void> sendRotary(String sessionId, int detents) async {
    final (backend, session) = _session(sessionId);
    _requireInputOwner(sessionId);
    await backend.sendRotary(session.id, detents);
  }

  @override
  Future<void> setAudioGain(
    String sessionId,
    String streamId,
    double gain,
  ) async {
    final (backend, session) = _session(sessionId);
    final route = _audio[streamId];
    if (route == null || route.$1 != backend || route.$2 != session.id) {
      throw StateError('Audio stream does not belong to the session.');
    }
    await backend.setAudioGain(session.id, route.$3, gain);
  }

  (ProjectionBackend, ProjectionSession) _session(String id) {
    _requireOpen();
    final route = _sessions[id];
    if (route == null || !_isLive(id)) {
      throw StateError('Unknown or ended projection session.');
    }
    return route;
  }

  void _requireInputOwner(String id) {
    if (_owner != id ||
        !_current.activeSession!.videoStreams.any(
          (s) => s.role == ProjectionVideoRole.main && s.visible && s.focused,
        )) {
      throw StateError('Projection session does not own visible input.');
    }
  }

  Future<void> _enqueue(Future<void> Function() command) {
    _requireOpen();
    final pending = _commandTail.then((_) {
      _requireOpen();
      return command();
    });
    _commandTail = pending.catchError((Object _) {});
    return pending;
  }

  void _requireOpen() {
    if (_closed) throw StateError('Projection backend is closed.');
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _commandTail;
    // All adapters receive cleanup even when one fails. Repeated close calls
    // share this future and never release an adapter twice.
    try {
      await Future.wait(_backends.map((backend) => backend.close()));
    } finally {
      await _changes.close();
    }
  }

  static String _id(ProjectionBackend backend, String kind, String local) =>
      '${backend.protocol!.name.toLowerCase()}.$kind.${_hex(local)}';
  String _sessionId(ProjectionBackend backend, String local) {
    final key = _id(backend, 'session', local);
    return '$key.${_identities[key]?.$1 ?? 0}';
  }

  String _streamId(
    ProjectionBackend backend,
    String kind,
    String session,
    String local,
  ) => '${_sessionId(backend, session)}.$kind.${_hex(local)}';
  static String _hex(String value) => utf8
      .encode(value)
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
}
