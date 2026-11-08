import 'dart:async';

import '../../core/media/media_session_service.dart';
import '../../core/connectivity/connectivity_service.dart';
import '../../core/media/media_state.dart';
import '../../core/projection/projection_models.dart';
import '../../core/projection/projection_service.dart';
import '../../core/projection/projection_types.dart';

/// Adapts existing projection sessions; does not own or activate a phone session.
final class ProjectionMediaSource {
  ProjectionMediaSource(
    ProjectionService projection,
    this.media, {
    this.connectivity,
    this.selectSource,
  }) {
    _projection = projection;
    _provider = media.register(
      'projection',
      select: selectSource,
      execute: _execute,
    );
    _subscription = projection.changes.listen(_replace);
    _replace(projection.current);
  }
  final ConnectivityService? connectivity;
  final Future<void> Function(MediaSourceState)? selectSource;
  late final ProjectionService _projection;
  final CachedMediaSessionService media;
  late final MediaProvider _provider;
  int _revision = 0;
  late final StreamSubscription<ProjectionSnapshot> _subscription;
  void _replace(ProjectionSnapshot snapshot) {
    final sources = <MediaSourceState>[];
    if (snapshot.backendAvailable) {
      for (final session in snapshot.sessions) {
        final metadata = session.metadata;
        if (session.state == ProjectionSessionState.failed ||
            session.state == ProjectionSessionState.disconnected) {
          continue;
        }
        sources.add(
          MediaSourceState(
            id: 'projection:${session.id}:media',
            kind: session.device.protocol == ProjectionProtocol.androidAuto
                ? MediaSourceKind.androidAuto
                : MediaSourceKind.carPlay,
            deviceId: session.device.id,
            sessionId: session.id,
            details: metadata?.media ?? const MediaDetails(),
            displayName:
                metadata?.phone.displayName ?? session.device.displayName,
            phone: metadata?.phone,
            commands: session.state == ProjectionSessionState.connecting
                ? const []
                : metadata?.mediaCommands ?? const [],
            revision: metadata?.revision ?? 0,
            updatedAtMs: metadata?.updatedAtMs ?? 0,
          ),
        );
      }
    }
    _provider.publish(++_revision, sources);
  }

  Future<void> _execute(MediaSourceState source, String command) async {
    final session = _projection.current.sessions
        .where(
          (s) =>
              s.id == source.sessionId &&
              s.device.id == source.deviceId &&
              s.state != ProjectionSessionState.failed &&
              s.state != ProjectionSessionState.disconnected,
        )
        .firstOrNull;
    if (session == null ||
        session.metadata?.mediaCommands.contains(command) != true) {
      throw StateError('The phone media session changed.');
    }
    final button = switch (command) {
      'previous' => ProjectionInputButton.previous,
      'next' => ProjectionInputButton.next,
      'playPause' => ProjectionInputButton.playPause,
      'play' => ProjectionInputButton.play,
      'pause' => ProjectionInputButton.pause,
      _ => throw UnsupportedError('Unsupported phone media command'),
    };
    await _projection.sendButton(session.id, button, pressed: true);
    await _projection.sendButton(session.id, button, pressed: false);
  }

  Future<void> close() async {
    await _subscription.cancel();
    _provider.close();
  }
}
