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
  }) {
    _connectivitySubscription = connectivity?.connectivityChanges.listen(
      (_) => _replace(projection.current),
    );
    _provider = media.register('projection');
    _subscription = projection.changes.listen(_replace);
    _replace(projection.current);
  }
  final ConnectivityService? connectivity;
  StreamSubscription<ConnectivitySnapshot>? _connectivitySubscription;
  final CachedMediaSessionService media;
  late final MediaProvider _provider;
  int _revision = 0;
  late final StreamSubscription<ProjectionSnapshot> _subscription;
  void _replace(ProjectionSnapshot snapshot) {
    final sources = <MediaSourceState>[];
    if (snapshot.backendAvailable) {
      for (final session in snapshot.sessions) {
        final metadata = session.metadata;
        if (metadata?.media == null ||
            session.state == ProjectionSessionState.failed ||
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
            details: metadata!.media!,
            commands:
                session.device.protocol == ProjectionProtocol.androidAuto &&
                    connectivity?.connectivity.music?['projection_commands'] ==
                        true &&
                    (session.state == ProjectionSessionState.streaming ||
                        session.state == ProjectionSessionState.suspended)
                ? const ['previous', 'play', 'pause', 'next']
                : const [],
            revision: metadata.revision,
            updatedAtMs: metadata.updatedAtMs,
          ),
        );
      }
    }
    _provider.publish(++_revision, sources);
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _connectivitySubscription?.cancel();
    _provider.close();
  }
}
