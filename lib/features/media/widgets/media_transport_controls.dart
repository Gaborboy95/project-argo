import 'package:flutter/material.dart';

import '../../../core/media/media_state.dart';

/// The icon describes the requested action; playback state is never changed
/// optimistically. Unknown state uses a true toggle only when one is supported.
String? mediaPrimaryCommand(MediaSourceState? source) {
  if (source == null) return null;
  final commands = source.commands;
  final playing = source.details.playback == MediaPlaybackState.playing;
  final known = const {
    MediaPlaybackState.playing,
    MediaPlaybackState.paused,
    MediaPlaybackState.stopped,
  }.contains(source.details.playback);
  if (commands.contains('playPause')) return 'playPause';
  if (playing && commands.contains('pause')) return 'pause';
  if (known && !playing && commands.contains('play')) return 'play';
  for (final toggle in ['toggle']) {
    if (commands.contains(toggle)) return toggle;
  }
  if (commands.contains('play')) return 'play';
  if (commands.contains('pause')) return 'pause';
  return null;
}

class MediaTransportControls extends StatelessWidget {
  const MediaTransportControls({
    super.key,
    required this.source,
    required this.onCommand,
    this.busy = false,
    this.extent = 64,
    this.filledPrimary = false,
  });

  final MediaSourceState? source;
  final ValueChanged<String> onCommand;
  final bool busy, filledPrimary;
  final double extent;

  @override
  Widget build(BuildContext context) {
    final primary = mediaPrimaryCommand(source);
    final playing = source?.details.playback == MediaPlaybackState.playing;
    final known = const {
      MediaPlaybackState.playing,
      MediaPlaybackState.paused,
      MediaPlaybackState.stopped,
    }.contains(source?.details.playback);
    final primaryIcon = primary == 'pause'
        ? Icons.pause_rounded
        : primary == 'play'
        ? Icons.play_arrow_rounded
        : !known
        ? null
        : playing
        ? Icons.pause_rounded
        : Icons.play_arrow_rounded;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final entry in [
          ('previous', Icons.skip_previous_rounded),
          (primary, primaryIcon),
          ('next', Icons.skip_next_rounded),
        ])
          SizedBox(
            width: extent,
            height: extent,
            child:
                entry.$1 != null && source?.commands.contains(entry.$1) == true
                ? _button(entry.$1!, entry.$2, entry.$1 == primary)
                : null,
          ),
      ],
    );
  }

  Widget _button(String command, IconData? icon, bool primary) {
    final tooltip = command == 'toggle' || command == 'playPause'
        ? 'Play/pause'
        : command;
    final child = icon == null
        ? SizedBox(
            width: extent * .64,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.play_arrow_rounded, size: extent * .30),
                Icon(Icons.pause_rounded, size: extent * .30),
              ],
            ),
          )
        : Icon(icon, size: extent * (primary ? .60 : .52));
    return filledPrimary && primary
        ? IconButton.filled(
            tooltip: tooltip,
            onPressed: busy ? null : () => onCommand(command),
            icon: child,
          )
        : IconButton(
            padding: EdgeInsets.zero,
            tooltip: tooltip,
            onPressed: busy ? null : () => onCommand(command),
            icon: child,
          );
  }
}
