import 'dart:async';

import '../audio/audio_service.dart';
import '../audio/audio_snapshot.dart';
import '../audio/audio_types.dart';
import '../diagnostics/diagnostics_service.dart';
import 'projection_backend.dart';
import 'projection_models.dart';
import 'projection_types.dart';

abstract interface class ProjectionService {
  ProjectionSnapshot get current;
  Stream<ProjectionSnapshot> get changes;

  Future<void> connect(String deviceId);
  Future<void> disconnect(String sessionId);
  Future<void> activate(String sessionId);
  Future<void> sendTouch(String sessionId, ProjectionTouch touch);
  Future<void> sendButton(
    String sessionId,
    ProjectionInputButton button, {
    required bool pressed,
  });
  Future<void> sendRotary(String sessionId, int detents);
  Future<void> setVideoVisibility(String streamId, bool visible);
  Future<void> close();
}

/// Protocol-neutral projection state and its integration with Argo audio focus.
final class DefaultProjectionService implements ProjectionService {
  DefaultProjectionService._({
    required this.backend,
    required this.audio,
    required this.diagnostics,
  }) : _current = backend.current;

  static Future<DefaultProjectionService> start({
    required ProjectionBackend backend,
    required AudioService audio,
    required DiagnosticsService diagnostics,
  }) async {
    final service = DefaultProjectionService._(
      backend: backend,
      audio: audio,
      diagnostics: diagnostics,
    );
    try {
      await backend.start();
      service._current = backend.current;
      service._backendSubscription = backend.changes.listen(
        service._onBackendSnapshot,
        onError: service._onBackendError,
      );
      service._audioSubscription = audio.changes.listen((_) {
        service._scheduleGains();
      });
      service._scheduleAudio();
      return service;
    } on Object catch (error, stackTrace) {
      try {
        await service.close();
      } on Object {
        // Preserve the startup failure.
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  final ProjectionBackend backend;
  final AudioService audio;
  final DiagnosticsService diagnostics;
  final StreamController<ProjectionSnapshot> _changes =
      StreamController<ProjectionSnapshot>.broadcast(sync: true);
  final Map<String, AudioFocusHandle> _focusHandles = {};
  final Set<String> _registeredAudioSources = {};
  ProjectionSnapshot _current;
  StreamSubscription<ProjectionSnapshot>? _backendSubscription;
  StreamSubscription<AudioSnapshot>? _audioSubscription;
  final Map<String, double> _sentAudioGains = {};
  Future<void>? _audioWork;
  bool _audioPending = false;
  bool _gainsRunning = false;
  bool _gainsPending = false;
  Timer? _gainDeadline;
  Timer? _retry;
  int _generation = 0;
  ProjectionAudioFailure? _audioFailure;
  ProjectionSnapshot? _authoritative;
  final Map<String, bool> _sourceActivity = {};
  bool _closed = false;
  bool _notificationPending = false;

  @override
  ProjectionSnapshot get current => _current;

  @override
  Stream<ProjectionSnapshot> get changes => _changes.stream;

  @override
  Future<void> connect(String deviceId) => backend.connect(deviceId);

  @override
  Future<void> disconnect(String sessionId) => backend.disconnect(sessionId);

  @override
  Future<void> activate(String sessionId) => backend.activate(sessionId);

  @override
  Future<void> sendTouch(String sessionId, ProjectionTouch touch) {
    touch.validate();
    return backend.sendTouch(sessionId, touch);
  }

  @override
  Future<void> sendButton(
    String sessionId,
    ProjectionInputButton button, {
    required bool pressed,
  }) => backend.sendButton(sessionId, button, pressed: pressed);

  @override
  Future<void> sendRotary(String sessionId, int detents) {
    if (detents == 0 || detents < -100 || detents > 100) {
      return Future.error(
        RangeError.range(detents, -100, 100, 'detents', 'Must be non-zero'),
      );
    }
    return backend.sendRotary(sessionId, detents);
  }

  @override
  Future<void> setVideoVisibility(String streamId, bool visible) =>
      backend.setVideoVisibility(streamId, visible);

  void _onBackendSnapshot(ProjectionSnapshot snapshot) {
    if (_closed) return;
    _generation++;
    _authoritative = snapshot;
    _publish();
    _scheduleAudio();
  }

  void _publish() {
    if (_closed) return;
    final snapshot = _authoritative ?? backend.current;
    final next = ProjectionSnapshot(
      backendAvailable: snapshot.backendAvailable,
      devices: snapshot.devices,
      sessions: snapshot.sessions,
      activeSessionId: snapshot.activeSessionId,
      failureMessage: snapshot.failureMessage,
      audioFailure: _audioFailure,
    );
    if (next == _current) return;
    _current = next;
    // Synchronous observers may issue another command. Publish once per turn
    // without reentering the broadcast controller or retaining old snapshots.
    if (_notificationPending) return;
    _notificationPending = true;
    scheduleMicrotask(() {
      _notificationPending = false;
      if (!_closed) _changes.add(_current);
    });
  }

  void _failedAudio(
    ProjectionAudioFailure cause,
    Object error,
    StackTrace stack,
  ) {
    if (_closed) return;
    _audioFailure = cause;
    _publish();
    diagnostics.error(
      'projection.audio',
      cause.message,
      error: error,
      stackTrace: stack,
    );
    // One retry timer, never one retry/future per arriving snapshot.
    _retry ??= Timer(const Duration(seconds: 1), () {
      _retry = null;
      _scheduleAudio();
    });
  }

  void _scheduleAudio() {
    if (_closed) return;
    _audioPending = true;
    if (_audioWork != null) return;
    _audioWork = _reconcileAudio().whenComplete(() {
      _audioWork = null;
      if (_audioPending && !_closed) _scheduleAudio();
    });
  }

  Future<void> _reconcileAudio() async {
    while (_audioPending && !_closed) {
      _audioPending = false;
      final generation = _generation;
      await _synchronizeAudio(_authoritative ?? backend.current, generation);
      if (!_closed && generation == _generation) _scheduleGains();
    }
  }

  void _scheduleGains() {
    if (_closed) return;
    _gainsPending = true;
    if (_gainsRunning) return;
    _gainsRunning = true;
    unawaited(
      _reconcileGains().whenComplete(() {
        _gainsRunning = false;
        if (_gainsPending && !_closed) _scheduleGains();
      }),
    );
  }

  Future<void> _reconcileGains() async {
    while (_gainsPending && !_closed) {
      _gainsPending = false;
      final generation = _generation;
      try {
        await _applyAudioGains(_authoritative ?? backend.current, generation);
        if (!_closed &&
            generation == _generation &&
            _audioFailure != ProjectionAudioFailure.focus) {
          _audioFailure = null;
          _publish();
        }
      } on Object catch (error, stack) {
        _failedAudio(ProjectionAudioFailure.gain, error, stack);
        // Self-generated audio events must not turn failure into a busy loop.
        if (generation == _generation) _gainsPending = false;
      }
    }
  }

  void _onBackendError(Object error, StackTrace stackTrace) {
    diagnostics.error(
      'projection.backend',
      'Projection backend stream failed.',
      error: error,
      stackTrace: stackTrace,
    );
  }

  Future<void> _releaseSource(String sourceId) async {
    // Unregister must still run if release fails, and other owners must proceed.
    Object? failure;
    StackTrace? failureStack;
    try {
      await _focusHandles[sourceId]?.release();
      _focusHandles.remove(sourceId);
    } on Object catch (error, stack) {
      failure = error;
      failureStack = stack;
    }
    try {
      await audio.unregisterSource(sourceId);
      _registeredAudioSources.remove(sourceId);
      _sourceActivity.remove(sourceId);
      _focusHandles.remove(sourceId);
    } on Object catch (error, stack) {
      failure ??= error;
      failureStack ??= stack;
    }
    if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
  }

  Future<void> _synchronizeAudio(
    ProjectionSnapshot snapshot,
    int generation,
  ) async {
    final streams = <String, ProjectionAudioStream>{
      for (final session in snapshot.sessions)
        for (final stream in session.audioStreams)
          _audioSourceId(stream): stream,
    };
    var failed = false;
    for (final sourceId in _registeredAudioSources.toList()) {
      if (streams.containsKey(sourceId)) continue;
      try {
        await _releaseSource(sourceId);
      } on Object catch (error, stack) {
        failed = true;
        _failedAudio(ProjectionAudioFailure.focus, error, stack);
      }
    }
    for (final entry in streams.entries) {
      if (_closed || generation != _generation) return;
      final sourceId = entry.key;
      final stream = entry.value;
      try {
        if (!_registeredAudioSources.contains(sourceId)) {
          await audio.registerSource(
            AudioSource(
              id: sourceId,
              role: audioRoleForProjection(stream.role),
            ),
          );
          _registeredAudioSources.add(sourceId);
        }
        if (_closed || generation != _generation) return;
        if (_sourceActivity[sourceId] != stream.active) {
          await audio.setSourceActive(sourceId, stream.active);
          _sourceActivity[sourceId] = stream.active;
        }
        if (_closed || generation != _generation) return;
        final wantsFocus = stream.active && stream.hasFocus;
        if (wantsFocus && !_focusHandles.containsKey(sourceId)) {
          _focusHandles[sourceId] = await audio.requestFocus(sourceId);
        } else if (!wantsFocus) {
          await _focusHandles[sourceId]?.release();
          _focusHandles.remove(sourceId);
        }
      } on Object catch (error, stack) {
        failed = true;
        _failedAudio(ProjectionAudioFailure.focus, error, stack);
      }
    }
    if (!failed && _audioFailure == ProjectionAudioFailure.focus) {
      _audioFailure = null;
      _publish();
    }
  }

  Future<void> _applyAudioGains(
    ProjectionSnapshot snapshot,
    int generation,
  ) async {
    final present = <String>{};
    for (final session in snapshot.sessions) {
      for (final stream in session.audioStreams) {
        if (_closed || generation != _generation) return;
        final id = _audioSourceId(stream);
        if (!stream.active) {
          _sentAudioGains.remove(id);
          continue;
        }
        present.add(id);
        final gain = audio.current.effectiveSourceGains[id] ?? 0;
        if (_sentAudioGains[id] == gain) continue;
        // A deadline reports degradation without abandoning the underlying call:
        // abandoning and retrying would accumulate unbounded native requests.
        _gainDeadline = Timer(const Duration(seconds: 2), () {
          _failedAudio(
            ProjectionAudioFailure.timeout,
            TimeoutException('Native projection gain deadline'),
            StackTrace.current,
          );
        });
        try {
          await backend.setAudioGain(session.id, stream.id, gain);
        } finally {
          _gainDeadline?.cancel();
          _gainDeadline = null;
        }
        if (_closed || generation != _generation) {
          _sentAudioGains.remove(id);
          return;
        }
        _sentAudioGains[id] = gain;
      }
    }
    _sentAudioGains.removeWhere((key, _) => !present.contains(key));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _backendSubscription?.cancel();
    await _audioSubscription?.cancel();
    _retry?.cancel();
    _gainDeadline?.cancel();
    await _audioWork;
    for (final sourceId in _registeredAudioSources.toList()) {
      try {
        await _releaseSource(sourceId);
      } on Object catch (error, stack) {
        diagnostics.error(
          'projection.audio',
          'Could not release projection audio owner.',
          error: error,
          stackTrace: stack,
        );
      }
    }
    try {
      // Backend owns cancellation of its outstanding native requests. Do not
      // wait for an uncooperative gain Future before releasing that owner.
      await backend.close();
    } finally {
      await _changes.close();
    }
  }

  static String _audioSourceId(ProjectionAudioStream stream) =>
      'projection.${_stablePart(stream.sessionId)}.${_stablePart(stream.id)}';

  static String _stablePart(String value) {
    final normalized = value.toLowerCase().replaceAll(
      RegExp('[^a-z0-9_-]'),
      '_',
    );
    return normalized.isEmpty ? 'stream' : normalized;
  }
}

AudioSourceRole audioRoleForProjection(ProjectionAudioRole role) =>
    switch (role) {
      ProjectionAudioRole.media => AudioSourceRole.media,
      ProjectionAudioRole.speech => AudioSourceRole.navigation,
      ProjectionAudioRole.system => AudioSourceRole.system,
      ProjectionAudioRole.communication => AudioSourceRole.communication,
    };
