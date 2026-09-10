import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/media/media_session_service.dart';
import '../../core/media/media_state.dart';
import '../../features/media/media_artwork.dart';
import 'dashboard_panel.dart';

class DashboardMediaStrip extends StatefulWidget {
  const DashboardMediaStrip({
    super.key,
    required this.media,
    required this.scale,
    this.expanded = false,
    this.dragEnabled = true,
    this.onOpen,
    this.onDismiss,
  });
  final MediaSessionService? media;
  final double scale;
  final bool expanded, dragEnabled;
  final VoidCallback? onOpen, onDismiss;
  @override
  State<DashboardMediaStrip> createState() => _DashboardMediaStripState();
}

class _DashboardMediaStripState extends State<DashboardMediaStrip> {
  bool _busy = false;
  double _drag = 0;
  Future<void> _command(String source, String command) async {
    setState(() => _busy = true);
    try {
      await widget.media!.command(source, command);
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Playback command unavailable.')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _controls(MediaSourceState? source, double extent) {
    final action = source?.details.playback == MediaPlaybackState.playing
        ? 'pause'
        : 'play';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final entry in [
          ('previous', Icons.skip_previous_rounded),
          (
            action,
            action == 'play' ? Icons.play_arrow_rounded : Icons.pause_rounded,
          ),
          ('next', Icons.skip_next_rounded),
        ])
          SizedBox(
            width: extent,
            height: extent,
            child: source?.commands.contains(entry.$1) == true
                ? IconButton(
                    padding: EdgeInsets.zero,
                    tooltip: entry.$1,
                    onPressed: _busy
                        ? null
                        : () => _command(source!.id, entry.$1),
                    icon: Icon(entry.$2, size: extent * .65),
                  )
                : null,
          ),
      ],
    );
  }

  Widget _titles(MediaDetails? details, double font) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        details?.title ?? 'No media selected',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: font,
          fontWeight: FontWeight.w600,
          height: 1.1,
        ),
      ),
      if (details?.artist != null)
        Text(
          details!.artist!,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: font * .78,
            height: 1.1,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
    ],
  );
  @override
  Widget build(BuildContext context) => StreamBuilder<Object?>(
    stream: widget.media?.changes,
    builder: (context, _) {
      final snapshot = widget.media?.current;
      final source = snapshot?.activeSource;
      final details = source?.details;
      if (widget.expanded) {
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Media',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close media',
                    onPressed: widget.onDismiss,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              LayoutBuilder(
                builder: (context, c) {
                  final art = math.min(c.maxWidth * .34, 280.0);
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      MediaArtwork(path: details?.artworkPath, size: art),
                      const SizedBox(width: 24),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _titles(details, 28 * widget.scale),
                            if (details?.album != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: Text(details!.album!),
                              ),
                            if (details?.application != null)
                              Text(details!.application!),
                            if (details?.positionMs != null)
                              Text(
                                '${_time(details!.positionMs!)}${details.durationMs == null ? '' : ' / ${_time(details.durationMs!)}'}',
                              ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 16),
              _controls(source, (76 * widget.scale).clamp(64, 100)),
              if (snapshot != null && snapshot.sources.isNotEmpty)
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 12,
                  children: [
                    for (final item in snapshot.sources)
                      ChoiceChip(
                        label: Text(item.displayName ?? item.kind.name),
                        selected: item.id == source?.id,
                        onSelected: _busy
                            ? null
                            : (_) async {
                                setState(() => _busy = true);
                                try {
                                  await widget.media!.selectSource(item.id);
                                } on Object {
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          'Could not select media source.',
                                        ),
                                      ),
                                    );
                                  }
                                } finally {
                                  if (mounted) setState(() => _busy = false);
                                }
                              },
                      ),
                  ],
                ),
            ],
          ),
        );
      }
      final compact = LayoutBuilder(
        builder: (context, c) {
          final extent = math.min(c.maxHeight, 88 * widget.scale);
          final side = math.max(0.0, (c.maxWidth - extent * 3) / 2);
          final textScale = MediaQuery.textScalerOf(context).scale(1);
          return Row(
            children: [
              SizedBox(
                width: side,
                child: Row(
                  children: [
                    MediaArtwork(
                      path: details?.artworkPath,
                      size: math.min(c.maxHeight, side * .4),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _titles(
                        details,
                        math.min(
                          19 * widget.scale,
                          c.maxHeight / (2.2 * textScale),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              _controls(source, extent),
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: IconButton(
                    tooltip: 'Expand media',
                    onPressed: widget.onOpen,
                    icon: const Icon(Icons.keyboard_arrow_up),
                    iconSize: 32,
                  ),
                ),
              ),
            ],
          );
        },
      );
      if (!widget.dragEnabled) return compact;
      return PanelDragRegion(
        onStart: () => _drag = 0,
        onUpdate: (delta) => _drag += delta,
        onEnd: (velocity) {
          if (_drag < -32 || velocity < -500) widget.onOpen?.call();
        },
        child: compact,
      );
    },
  );
  String _time(int ms) =>
      '${ms ~/ 60000}:${((ms ~/ 1000) % 60).toString().padLeft(2, '0')}';
}
