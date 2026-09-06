import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/projection/projection_models.dart';
import '../../core/projection/projection_service.dart';
import '../../core/projection/projection_types.dart';
import '../projection/projection_view.dart';

class MediaPage extends StatefulWidget {
  const MediaPage({
    super.key,
    required this.projection,
    this.rendererTest = false,
  });

  final ProjectionService projection;
  final bool rendererTest;

  @override
  State<MediaPage> createState() => _MediaPageState();
}

class _MediaPageState extends State<MediaPage> {
  late ProjectionSnapshot _snapshot;
  bool _returning = false;
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

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.rendererTest
                      ? 'Native renderer test — no phone'
                      : 'Projection',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
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
          const SizedBox(height: 12),
          Expanded(
            child: Card(
              clipBehavior: Clip.antiAlias,
              child: widget.rendererTest
                  ? const ProjectionView.rendererTest()
                  : stream != null &&
                        session?.state == ProjectionSessionState.streaming
                  ? ProjectionView(
                      service: widget.projection,
                      inputEnabled: !_returning,
                      sessionId: session!.id,
                      stream: stream,
                    )
                  : _ProjectionStatus(
                      snapshot: _snapshot,
                      session: session,
                      onConnect: _snapshot.devices.isEmpty
                          ? null
                          : () => widget.projection.connect(
                              _snapshot.devices.first.id,
                            ),
                    ),
            ),
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
          null when !snapshot.backendAvailable => 'Projection is disabled',
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
