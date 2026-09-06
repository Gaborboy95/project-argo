import 'package:flutter/material.dart';

import '../../core/projection/projection_models.dart';
import '../../core/projection/projection_service.dart';
import '../../core/projection/projection_types.dart';
import 'projection_input_scope.dart';
import 'projection_presentation_scope.dart';
import 'projection_view.dart';

/// The sole native projection surface owner. Offstage removes its layer/input
/// without disposing the native consumer during ordinary host navigation.
class ProjectionPage extends StatelessWidget {
  const ProjectionPage({
    super.key,
    required this.projection,
    this.rendererTest = false,
    this.geometryDiagnostics = false,
  });
  final ProjectionService projection;
  final bool rendererTest, geometryDiagnostics;

  @override
  Widget build(BuildContext context) => StreamBuilder<ProjectionSnapshot>(
    stream: projection.changes,
    builder: (context, _) {
      final snapshot = projection.current;
      final session = selectedProjectionSession(snapshot);
      final stream = mainProjectionStream(session);
      final presentation = ProjectionPresentationScope.of(context);
      final owns = ProjectionInputScope.activeOf(context);
      final usable =
          owns &&
          (rendererTest ||
              (projectionVideoUsable(session) &&
                  presentation?.waiting != true));
      return ColoredBox(
        color: usable ? Colors.black : Theme.of(context).colorScheme.surface,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Offstage(
              offstage: !usable,
              child: rendererTest
                  ? ProjectionView.rendererTest(
                      key: const ValueKey('renderer-test'),
                      geometryDiagnostics: geometryDiagnostics,
                    )
                  : stream == null
                  ? const SizedBox.expand()
                  : ProjectionView(
                      key: ValueKey((session!.id, stream.id)),
                      service: projection,
                      sessionId: session.id,
                      stream: stream,
                      inputEnabled: usable,
                      geometryDiagnostics: geometryDiagnostics,
                    ),
            ),
            if (!usable)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.screen_share_outlined, size: 64),
                      const SizedBox(height: 16),
                      Text(
                        presentation?.error ??
                            snapshot.failureMessage ??
                            projectionConnectionStatus(
                              snapshot,
                              session ?? snapshot.sessions.firstOrNull,
                            ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}

ProjectionSession? selectedProjectionSession(ProjectionSnapshot snapshot) {
  bool live(ProjectionSession s) =>
      s.state != ProjectionSessionState.failed &&
      s.state != ProjectionSessionState.disconnected;
  final active = snapshot.activeSession;
  if (active != null && live(active)) return active;
  return snapshot.sessions.where(live).firstOrNull;
}

ProjectionVideoStream? mainProjectionStream(ProjectionSession? session) =>
    session?.videoStreams
        .where((s) => s.role == ProjectionVideoRole.main)
        .firstOrNull;

bool projectionVideoUsable(ProjectionSession? session) {
  final stream = mainProjectionStream(session);
  return session?.state == ProjectionSessionState.streaming &&
      stream != null &&
      stream.visible &&
      stream.focused;
}

String projectionConnectionStatus(
  ProjectionSnapshot snapshot,
  ProjectionSession? session,
) => switch (session?.state) {
  ProjectionSessionState.connecting => 'Connecting…',
  ProjectionSessionState.ready => 'Connected — waiting for video…',
  ProjectionSessionState.streaming => 'Waiting for projection video…',
  ProjectionSessionState.suspended =>
    'Projection suspended — select Home to resume',
  ProjectionSessionState.failed =>
    session?.failureMessage ?? 'Projection failed',
  ProjectionSessionState.disconnected => 'Device disconnected',
  null when !snapshot.backendAvailable => 'Projection is disabled',
  null when snapshot.devices.isEmpty => 'No device',
  null => 'Device discovered — waiting for connection…',
};
