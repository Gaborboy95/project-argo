import '../../core/media/media_session_service.dart';
import '../../core/media/media_state.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/projection/projection_models.dart';
import '../../core/projection/projection_service.dart';
import '../../core/projection/projection_types.dart';
import '../../core/projection/projection_touch_mapper.dart';
import '../projection/projection_presentation_scope.dart';
import '../projection/projection_view.dart';

class MediaPage extends StatefulWidget {
  const MediaPage({
    super.key,
    required this.projection,
    this.rendererTest = false,
    this.media,
    this.geometryDiagnostics = false,
  });

  final ProjectionService projection;
  final MediaSessionService? media;
  final bool rendererTest;
  final bool geometryDiagnostics;

  @override
  State<MediaPage> createState() => _MediaPageState();
}

class _MediaPageState extends State<MediaPage> {
  late ProjectionSnapshot _snapshot;
  bool _returning = false;
  final _surfaceKey = GlobalKey();
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
  Widget build(BuildContext context) {
    final session =
        _snapshot.activeSession ??
        (_snapshot.sessions.isEmpty ? null : _snapshot.sessions.first);
    ProjectionVideoStream? stream;
    for (final candidate in session?.videoStreams ?? const []) {
      if (candidate.role == ProjectionVideoRole.main) {
        stream = candidate;
        break;
      }
    }

    final presentation = ProjectionPresentationScope.of(context);
    final expanded = presentation?.expanded ?? false;
    final hasVideo =
        widget.rendererTest ||
        (stream != null && session?.state == ProjectionSessionState.streaming);
    final Widget surface = widget.rendererTest
        ? ProjectionView.rendererTest(
            key: _surfaceKey,
            geometryDiagnostics: widget.geometryDiagnostics,
            preferPhysicalPixels: expanded,
          )
        : hasVideo
        ? ProjectionView(
            key: _surfaceKey,
            service: widget.projection,
            sessionId: session!.id,
            stream: stream!,
            inputEnabled: !_returning,
            geometryDiagnostics: widget.geometryDiagnostics,
            preferPhysicalPixels: expanded,
          )
        : _ProjectionStatus(
            snapshot: _snapshot,
            session: session,
            onConnect: _snapshot.devices.isEmpty
                ? null
                : () => widget.projection.connect(_snapshot.devices.first.id),
          );
    if (expanded) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final geometry = hasVideo
              ? ProjectionViewGeometry(
                  width: constraints.maxWidth,
                  height: constraints.maxHeight,
                  devicePixelRatio: View.of(context).devicePixelRatio,
                  preferPhysicalPixels: true,
                ).fit(stream?.width ?? 1280, stream?.height ?? 720)
              : null;
          return Stack(
            fit: StackFit.expand,
            children: [
              surface,
              Positioned(
                top: 8,
                left: 8,
                right: 8,
                child: SafeArea(
                  child: Material(
                    color: Theme.of(context).colorScheme.surface
                        .withValues(alpha: 0.9),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        children: [
                          TextButton.icon(
                            onPressed: () => presentation!.setExpanded(false),
                            icon: const Icon(Icons.close_fullscreen),
                            label: const Text('Back to Argo'),
                          ),
                          if (geometry != null)
                            Text(
                              '${geometry.physicalWidth.toStringAsFixed(1)} × ${geometry.physicalHeight.toStringAsFixed(1)} px'
                              ' · ${geometry.isOneToOne ? "1:1 physical pixels" : "scaled to fit"}'
                              '${widget.rendererTest ? " · no phone" : ""}',
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      );
    }

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                widget.rendererTest
                    ? 'Native renderer test — no phone'
                    : 'Projection',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              if (hasVideo && presentation != null)
                TextButton.icon(
                  onPressed: () => presentation.setExpanded(true),
                  icon: const Icon(Icons.open_in_full),
                  label: const Text('Compare size'),
                ),
              if (stream != null &&
                  session?.state == ProjectionSessionState.streaming)
                TextButton(
                  onPressed: () {
                    setState(() => _returning = true);
                    unawaited(
                      widget.projection.setVideoVisibility(stream!.id, false),
                    );
                  },
                  child: const Text('Return to Argo'),
                ),
              if (session?.state == ProjectionSessionState.suspended)
                TextButton(
                  onPressed: () {
                    setState(() => _returning = false);
                    unawaited(widget.projection.activate(session!.id));
                  },
                  child: const Text('Show projection'),
                ),
            ],
          ),
          if (!widget.rendererTest)
            Flexible(
              child: SizedBox(
                height: 104,
                child: _MediaFacts(session: session, media: widget.media),
              ),
            ),
          const SizedBox(height: 12),
          Expanded(
            flex: widget.rendererTest ? 1 : 3,
            child: Card(clipBehavior: Clip.antiAlias, child: surface),
          ),
        ],
      ),
    );
  }
}

class _ProjectionStatus extends StatelessWidget {
  const _ProjectionStatus({
    required this.snapshot,
    required this.session,
    required this.onConnect,
  });

  final ProjectionSnapshot snapshot;
  final ProjectionSession? session;
  final Future<void> Function()? onConnect;

  @override
  Widget build(BuildContext context) {
    final state = session?.state;
    final label =
        snapshot.failureMessage ??
        switch (state) {
          ProjectionSessionState.connecting => 'Connecting…',
          ProjectionSessionState.ready => 'Connected',
          ProjectionSessionState.streaming => 'Starting projection video…',
          ProjectionSessionState.suspended => 'Projection suspended',
          ProjectionSessionState.failed =>
            session?.failureMessage ?? 'Projection failed',
          ProjectionSessionState.disconnected => 'Device disconnected',
          null when !snapshot.backendAvailable =>
            snapshot.failureMessage ?? 'Projection is disabled',
          null when snapshot.devices.isEmpty => 'No device',
          null => 'Device discovered',
        };
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.screen_share_outlined, size: 64),
          const SizedBox(height: 16),
          Text(label, textAlign: TextAlign.center),
          if (onConnect != null && session == null) ...[
            const SizedBox(height: 16),
            FilledButton(onPressed: onConnect, child: const Text('Connect')),
          ],
        ],
      ),
    );
  }
}

class _MediaFacts extends StatelessWidget {
  const _MediaFacts({required this.session, required this.media});
  final ProjectionSession? session;
  final MediaSessionService? media;
  @override
  Widget build(BuildContext context) => StreamBuilder<MediaSessionSnapshot>(
    stream: media?.changes,
    builder: (context, _) {
      final s = session;
      final live =
          s != null &&
          s.state != ProjectionSessionState.failed &&
          s.state != ProjectionSessionState.disconnected;
      final phone = live ? s.metadata?.phone : null;
      final source = media?.current.activeSource;
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
