import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/media/media_session_service.dart';
import '../../core/media/media_state.dart';
import '../../features/media/media_artwork.dart';

class DashboardMediaStrip extends StatefulWidget {
  const DashboardMediaStrip({
    super.key,
    required this.media,
    required this.scale,
  });
  final MediaSessionService? media;
  final double scale;
  @override
  State<DashboardMediaStrip> createState() => _DashboardMediaStripState();
}

class _DashboardMediaStripState extends State<DashboardMediaStrip> {
  bool _busy = false;
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

  @override
  Widget build(BuildContext context) => StreamBuilder<Object?>(
    stream: widget.media?.changes,
    builder: (context, _) {
      final source = widget.media?.current.activeSource;
      final details = source?.details;
      final action = details?.playback == MediaPlaybackState.playing
          ? 'pause'
          : 'play';
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            SizedBox(
              width: 40,
              height: 40,
              child: MediaArtwork(path: details?.artworkPath, size: 40),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: details?.title ?? 'No media selected',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    if (details?.artist != null)
                      TextSpan(
                        text: '  ·  ${details!.artist!}',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14 * widget.scale),
              ),
            ),
            for (final entry in [
              ('previous', Icons.skip_previous_rounded),
              (
                action,
                action == 'play'
                    ? Icons.play_arrow_rounded
                    : Icons.pause_rounded,
              ),
              ('next', Icons.skip_next_rounded),
            ])
              if (source?.commands.contains(entry.$1) == true)
                IconButton(
                  tooltip: entry.$1,
                  onPressed: _busy
                      ? null
                      : () => _command(source!.id, entry.$1),
                  icon: Icon(entry.$2, size: 24 * widget.scale),
                ),
          ],
        ),
      );
    },
  );
}
