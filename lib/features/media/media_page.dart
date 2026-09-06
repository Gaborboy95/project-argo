import '../../core/media/media_session_service.dart';
import '../../core/media/media_state.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/projection/projection_models.dart';
import '../../core/projection/projection_service.dart';
import '../../core/projection/projection_types.dart';

class MediaPage extends StatefulWidget {
  const MediaPage({super.key, required this.projection, this.media});

  final ProjectionService projection;
  final MediaSessionService? media;

  @override
  State<MediaPage> createState() => _MediaPageState();
}

class _MediaPageState extends State<MediaPage> {
  late ProjectionSnapshot _snapshot;
  StreamSubscription<ProjectionSnapshot>? _subscription;

  @override
  void initState() {
    super.initState();
    _snapshot = widget.projection.current;
    _subscription = widget.projection.changes.listen((snapshot) {
      if (mounted) setState(() => _snapshot = snapshot);
    });
  }

  @override
  void didUpdateWidget(MediaPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.projection == widget.projection) return;
    unawaited(_subscription?.cancel());
    _snapshot = widget.projection.current;
    _subscription = widget.projection.changes.listen((snapshot) {
      if (mounted) setState(() => _snapshot = snapshot);
    });
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Now Playing', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 16),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  label: 'Music artwork unavailable',
                  child: Container(
                    width: 160,
                    height: 160,
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest,
                    child: Icon(
                      Icons.music_note_outlined,
                      size: 64,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                _MediaFacts(snapshot: _snapshot, media: widget.media),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

class _MediaFacts extends StatelessWidget {
  const _MediaFacts({required this.snapshot, required this.media});
  final ProjectionSnapshot snapshot;
  final MediaSessionService? media;
  @override
  Widget build(BuildContext context) => StreamBuilder<MediaSessionSnapshot>(
    stream: media?.changes,
    builder: (context, _) {
      final source = media?.current.activeSource;
      final s = snapshot.sessions
          .where(
            (s) => source != null
                ? s.id == source.sessionId && s.device.id == source.deviceId
                : s.state != ProjectionSessionState.failed &&
                      s.state != ProjectionSessionState.disconnected,
          )
          .firstOrNull;
      final live =
          s != null &&
          s.state != ProjectionSessionState.failed &&
          s.state != ProjectionSessionState.disconnected;
      final phone = live ? s.metadata?.phone : null;
      final details = source?.details;
      String time(int ms) =>
          '${ms ~/ 60000}:${((ms ~/ 1000) % 60).toString().padLeft(2, '0')}';
      return SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              live
                  ? '${s.device.protocol.name} / ${s.device.transport.name} · ${phone?.displayName ?? s.device.displayName}'
                  : 'No connected projection phone',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (details?.application != null)
              Text(
                details!.application!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            Text(
              details?.title ?? 'Track unavailable',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (details?.artist != null || details?.album != null)
              Text(
                [
                  details?.artist,
                  details?.album,
                ].whereType<String>().join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            Text(
              '${details?.playback.name ?? "unknown"}'
              '${details?.positionMs == null ? "" : " · reported ${time(details!.positionMs!)}"}'
              '${details?.durationMs == null ? "" : " / ${time(details!.durationMs!)}"}'
              '${phone?.batteryPercent == null ? "" : " · Phone battery ${phone!.batteryPercent}%"}'
              '${phone?.criticalBattery == true ? " · Phone battery critical" : ""}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      );
    },
  );
}
