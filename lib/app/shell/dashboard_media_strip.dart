import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/media/media_session_service.dart';
import '../../core/media/media_state.dart';
import '../../features/media/media_artwork.dart';
import '../../features/media/widgets/media_transport_controls.dart';
import '../../features/media/widgets/now_playing_panel.dart';
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
    this.onDevices,
  });
  final MediaSessionService? media;
  final double scale;
  final bool expanded, dragEnabled;
  final VoidCallback? onOpen, onDismiss, onDevices;
  @override
  State<DashboardMediaStrip> createState() => _DashboardMediaStripState();
}

class _DashboardMediaStripState extends State<DashboardMediaStrip> {
  bool _busy = false;
  double _drag = 0;
  Future<void> _command(String source, String command) async {
    if (_busy || widget.media == null) return;
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

  Widget _controls(
    MediaSourceState? source,
    double extent, {
    bool unavailable = false,
  }) => MediaTransportControls(
    source: source,
    busy: _busy || unavailable,
    extent: extent,
    onCommand: (command) => _command(source!.id, command),
  );

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
    builder: (context, status) {
      final snapshot = widget.media?.current;
      final source = snapshot?.activeSource;
      final details = source?.details;
      if (widget.expanded) {
        return Padding(
          padding: const EdgeInsets.all(16),
          child: NowPlayingPanel(
            media: widget.media,
            scale: widget.scale,
            onClose: widget.onDismiss,
            onDevices: widget.onDevices,
            prioritizeControls: true,
          ),
        );
      }
      final compact = LayoutBuilder(
        builder: (context, c) {
          final textScale = MediaQuery.textScalerOf(context).scale(1);
          if (c.maxWidth < 480 && c.maxHeight >= 76) {
            final metadataHeight = c.maxHeight - 56;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Column(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        MediaArtwork(
                          path: details?.artworkPath,
                          size: math.min(48, metadataHeight),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _titles(
                            details,
                            math.min(
                              22 * widget.scale,
                              metadataHeight / (2.2 * textScale),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    height: 48,
                    child: Row(
                      children: [
                        Expanded(
                          child: Center(
                            child: _controls(
                              source,
                              48,
                              unavailable: status.hasError,
                            ),
                          ),
                        ),
                        _expandControl(),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }
          final verticalPadding = c.maxHeight >= 80 ? 8.0 : 4.0;
          final height = math.max(0.0, c.maxHeight - 2 * verticalPadding);
          final art = c.maxWidth < 400 && c.maxHeight < 76
              ? 0.0
              : math.min(height, 72 * widget.scale);
          final gap = art > 0 ? 12.0 : 0.0;
          final extent = math.min(
            math.min(height, 64 * widget.scale),
            math.max(0.0, (c.maxWidth - 24 - art - gap - 48 - 48) / 3),
          );
          return Padding(
            padding: EdgeInsets.symmetric(
              horizontal: 12,
              vertical: verticalPadding,
            ),
            child: Row(
              children: [
                if (art > 0) ...[
                  MediaArtwork(path: details?.artworkPath, size: art),
                  SizedBox(width: gap),
                ],
                Expanded(
                  child: _titles(
                    details,
                    math.min(22 * widget.scale, height / (2.2 * textScale)),
                  ),
                ),
                _controls(source, extent, unavailable: status.hasError),
                _expandControl(),
              ],
            ),
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
  Widget _expandControl() => SizedBox(
    width: 48,
    height: double.infinity,
    child: IconButton(
      tooltip: 'Expand media',
      onPressed: widget.onOpen,
      icon: const Icon(Icons.keyboard_arrow_up),
      iconSize: 32,
      padding: EdgeInsets.zero,
    ),
  );
}
