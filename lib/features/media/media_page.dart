import 'package:flutter/material.dart';

import '../../core/connectivity/connectivity_service.dart';
import '../../core/media/media_session_service.dart';
import '../../core/projection/projection_models.dart';
import '../../core/projection/projection_service.dart';
import 'widgets/now_playing_panel.dart';

/// Playback lives here; device connections are owned by the Devices hub.
class MediaPage extends StatelessWidget {
  const MediaPage({
    super.key,
    required this.projection,
    this.media,
    this.connectivity,
    this.onDevices,
  });

  final ProjectionService projection;
  final MediaSessionService? media;
  final ConnectivityService? connectivity;
  final VoidCallback? onDevices;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => StreamBuilder<ProjectionSnapshot>(
      stream: projection.changes,
      initialData: projection.current,
      builder: (context, snapshot) => SingleChildScrollView(
        key: const ValueKey('media-page-scroll'),
        padding: EdgeInsets.all(
          constraints.maxWidth < 600 || constraints.maxHeight < 440 ? 12 : 24,
        ),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1120),
            child: Material(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(24),
              child: Padding(
                padding: EdgeInsets.all(
                  constraints.maxWidth < 400 || constraints.maxHeight < 440
                      ? 16
                      : 24,
                ),
                child: NowPlayingPanel(
                  media: media,
                  projectionSnapshot: snapshot.data,
                  onDevices: onDevices,
                  prioritizeControls: constraints.maxHeight < 440,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
