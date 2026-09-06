import 'dart:async';

import '../../core/media/media_session_service.dart';
import '../../core/media/media_state.dart';
import '../../core/projection/projection_models.dart';
import '../../core/projection/projection_service.dart';
import '../../core/projection/projection_types.dart';

/// Adapts existing projection sessions; does not own or activate a phone session.
final class ProjectionMediaSource {
  ProjectionMediaSource(ProjectionService projection, this.media) {
    _subscription = projection.changes.listen(_replace);
    _replace(projection.current);
  }
  final CachedMediaSessionService media;
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
            revision: metadata.revision,
            updatedAtMs: metadata.updatedAtMs,
          ),
        );
      }
    }
    // Media selection is independent of which projection surface is visible.
    final selected = sources.any((s) => s.id == media.current.activeSourceId)
        ? media.current.activeSourceId
        : sources.firstOrNull?.id;
    media.replace(
      MediaSessionSnapshot(sources: sources, activeSourceId: selected),
    );
  }

  Future<void> close() => _subscription.cancel();
}
