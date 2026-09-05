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
      await service._synchronizeAudio(service._current);
      service._audioSubscription = audio.changes.listen((_) {
        service._updateTail = service._updateTail
            .then((_) async {
              if (!service._closed) {
                await service._applyAudioGains(service._current);
              }
            })
            .catchError((Object error, StackTrace stack) {
              diagnostics.error(
                'projection.audio',
                'Native source gain update failed.',
                error: error,
                stackTrace: stack,
              );
            });
      });
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
  Future<void> _updateTail = Future<void>.value();
  bool _closed = false;

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
    _updateTail = _updateTail
        .then((_) async {
          if (_closed) return;
          await _synchronizeAudio(snapshot);
          if (snapshot != _current) {
            _current = snapshot;
            _changes.add(snapshot);
          }
        })
        .catchError((Object error, StackTrace stackTrace) {
          diagnostics.error(
            'projection.audio',
            'Could not synchronize projection audio focus.',
            error: error,
            stackTrace: stackTrace,
          );
        });
  }

  void _onBackendError(Object error, StackTrace stackTrace) {
    diagnostics.error(
      'projection.backend',
      'Projection backend stream failed.',
      error: error,
      stackTrace: stackTrace,
    );
  }

  Future<void> _synchronizeAudio(ProjectionSnapshot snapshot) async {
    final streams = <String, ProjectionAudioStream>{};
    for (final session in snapshot.sessions) {
      for (final stream in session.audioStreams) {
        streams[_audioSourceId(stream)] = stream;
      }
    }

    for (final sourceId in _registeredAudioSources.toList()) {
      if (streams.containsKey(sourceId)) continue;
      await _focusHandles.remove(sourceId)?.release();
      await audio.unregisterSource(sourceId);
      _registeredAudioSources.remove(sourceId);
    }

    for (final entry in streams.entries) {
      final sourceId = entry.key;
      final stream = entry.value;
      if (_registeredAudioSources.add(sourceId)) {
        await audio.registerSource(
          AudioSource(id: sourceId, role: audioRoleForProjection(stream.role)),
        );
      }
      await audio.setSourceActive(sourceId, stream.active);
      final wantsFocus = stream.active && stream.hasFocus;
      if (wantsFocus && !_focusHandles.containsKey(sourceId)) {
        _focusHandles[sourceId] = await audio.requestFocus(sourceId);
      } else if (!wantsFocus) {
        await _focusHandles.remove(sourceId)?.release();
      }
    }
    await _applyAudioGains(snapshot);
  }

  Future<void> _applyAudioGains(ProjectionSnapshot snapshot) async {
    final present = <String>{};
    for (final session in snapshot.sessions) {
      for (final stream in session.audioStreams) {
        final id = _audioSourceId(stream);
        if (!stream.active) {
          _sentAudioGains.remove(id);
          continue;
        }
        present.add(id);
        final gain = audio.current.effectiveSourceGains[id] ?? 0;
        if (_sentAudioGains[id] == gain) continue;
        await backend.setAudioGain(session.id, stream.id, gain);
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
    await _updateTail;
    for (final handle in _focusHandles.values.toList()) {
      await handle.release();
    }
    _focusHandles.clear();
    for (final sourceId in _registeredAudioSources.toList()) {
      await audio.unregisterSource(sourceId);
    }
    _registeredAudioSources.clear();
    await backend.close();
    await _changes.close();
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
