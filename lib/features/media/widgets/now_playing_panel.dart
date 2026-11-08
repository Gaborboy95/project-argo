import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/media/media_session_service.dart';
import '../../../core/media/media_state.dart';
import '../../../core/projection/projection_models.dart';
import '../../../core/projection/projection_types.dart';
import '../media_artwork.dart';
import 'media_transport_controls.dart';

String mediaKindLabel(MediaSourceKind kind) => switch (kind) {
  MediaSourceKind.androidAuto => 'Android Auto',
  MediaSourceKind.carPlay => 'CarPlay',
  MediaSourceKind.bluetooth => 'Bluetooth',
  MediaSourceKind.local => 'Local media',
};

IconData mediaKindIcon(MediaSourceKind kind) => switch (kind) {
  MediaSourceKind.androidAuto => Icons.android,
  MediaSourceKind.carPlay => Icons.phone_iphone_outlined,
  MediaSourceKind.bluetooth => Icons.bluetooth,
  MediaSourceKind.local => Icons.library_music_outlined,
};

String mediaTime(int milliseconds) {
  final seconds = math.max(0, milliseconds ~/ 1000);
  final minutes = seconds ~/ 60;
  if (minutes >= 60) {
    return '${minutes ~/ 60}:${(minutes % 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
  }
  return '$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
}

/// Shared now-playing content for Media and the expanded dashboard player.
/// Its host owns scrolling and the size reserved for projection.
class NowPlayingPanel extends StatefulWidget {
  const NowPlayingPanel({
    super.key,
    required this.media,
    this.projectionSnapshot,
    this.onDevices,
    this.onClose,
    this.scale = 1,
    this.prioritizeControls = false,
  });
  final MediaSessionService? media;
  final ProjectionSnapshot? projectionSnapshot;
  final VoidCallback? onDevices, onClose;
  final double scale;
  final bool prioritizeControls;

  @override
  State<NowPlayingPanel> createState() => _NowPlayingPanelState();
}

class _NowPlayingPanelState extends State<NowPlayingPanel> {
  bool _busy = false;
  String? _error, _errorSource;

  Future<void> _run(
    Future<void> Function() action, {
    String? sourceId,
    bool selection = false,
  }) async {
    if (_busy) return;
    final service = widget.media;
    final sourceSession = service?.current.sources
        .where((source) => source.id == sourceId)
        .firstOrNull
        ?.sessionId;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on Object {
      if (mounted &&
          identical(widget.media, service) &&
          (sourceId == null ||
              service?.current.activeSource?.id == sourceId &&
                  service?.current.activeSource?.sessionId == sourceSession)) {
        setState(() {
          _errorSource = sourceId;
          _error = selection
              ? 'Could not switch media source. Check the phone and try again.'
              : 'Could not control playback. Check the phone and try again.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<MediaSessionSnapshot>(
    stream: widget.media?.changes,
    initialData: widget.media?.current,
    builder: (context, state) {
      final snapshot = state.data ?? widget.media?.current;
      final source = snapshot?.activeSource;
      final error = state.hasError
          ? 'Media information is temporarily unavailable.'
          : _errorSource == null || _errorSource == source?.id
          ? _error
          : null;
      final available = !state.hasError && !_busy;
      return LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 520;
          final controlsFirst = narrow || widget.prioritizeControls;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Now Playing',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  if (widget.onClose != null)
                    IconButton(
                      tooltip: 'Close media',
                      onPressed: widget.onClose,
                      icon: const Icon(Icons.keyboard_arrow_down_rounded),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              if (snapshot != null && snapshot.sources.isNotEmpty)
                _sources(snapshot, available),
              if (_busy) ...[
                const SizedBox(height: 8),
                const LinearProgressIndicator(minHeight: 2),
              ],
              if (error != null) ...[
                const SizedBox(height: 12),
                Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              if (source == null)
                _empty(snapshot)
              else ...[
                const SizedBox(height: 16),
                if (controlsFirst) ...[
                  _controls(source, available),
                  const SizedBox(height: 20),
                ],
                _track(source, narrow),
                const SizedBox(height: 20),
                _progress(source.details),
                if (!controlsFirst) ...[
                  const SizedBox(height: 20),
                  _controls(source, available),
                ],
                if (source.commands.isEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Playback controls are not available from this source.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                _phone(source),
                _playbackOptions(source.details),
              ],
            ],
          );
        },
      );
    },
  );

  Widget _sources(MediaSessionSnapshot snapshot, bool available) {
    final active = snapshot.activeSource;
    if (snapshot.sources.length == 1 && active != null) {
      return Row(
        children: [
          Icon(mediaKindIcon(active.kind), size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _sourceLabel(active),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
        ],
      );
    }
    return DropdownButtonFormField<String>(
      key: ValueKey('media-source:${snapshot.activeSourceId}'),
      initialValue: snapshot.activeSourceId,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Media source'),
      items: [
        for (final source in snapshot.sources)
          DropdownMenuItem(
            value: source.id,
            child: Text(
              _sourceLabel(source),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: available
          ? (id) {
              if (id != null && id != snapshot.activeSourceId) {
                _run(() => widget.media!.selectSource(id), selection: true);
              }
            }
          : null,
    );
  }

  String _sourceLabel(MediaSourceState source) {
    final name = source.displayName?.trim();
    return name == null || name.isEmpty
        ? mediaKindLabel(source.kind)
        : '${mediaKindLabel(source.kind)} · $name';
  }

  Widget _empty(MediaSessionSnapshot? snapshot) {
    final live = widget.projectionSnapshot?.sessions
        .where(
          (s) =>
              s.state != ProjectionSessionState.failed &&
              s.state != ProjectionSessionState.disconnected,
        )
        .firstOrNull;
    final connecting = live?.state == ProjectionSessionState.connecting;
    final choose = snapshot?.sources.isNotEmpty == true;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        children: [
          Icon(
            connecting
                ? Icons.phonelink_ring_outlined
                : Icons.music_note_rounded,
            size: 56,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(
            choose
                ? 'Choose a media source'
                : connecting
                ? 'Connecting to ${live!.device.displayName}'
                : live != null
                ? 'Ready to play'
                : 'No media selected',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            choose
                ? 'Choose a connected source above to control its playback.'
                : live != null
                ? 'Start music or a podcast on your phone. Track details appear here when available.'
                : 'Connect a phone in Devices, then start music or a podcast.',
            textAlign: TextAlign.center,
          ),
          if (widget.onDevices != null) ...[
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: widget.onDevices,
              icon: const Icon(Icons.devices_outlined),
              label: const Text('Open Devices'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _track(MediaSourceState source, bool narrow) {
    final details = source.details;
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(1);
        final art = math.min(
          narrow ? 112.0 : 220.0,
          constraints.maxWidth * .32,
        );
        final metadata = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (details.application?.trim().isNotEmpty == true) ...[
              Text(
                details.application!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge
                    ?.copyWith(color: colors.primary),
              ),
              const SizedBox(height: 8),
            ],
            Text(
              details.title?.trim().isNotEmpty == true
                  ? details.title!
                  : 'Track details unavailable',
              maxLines: narrow ? 3 : 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
                fontSize: (narrow ? 24 : 32) * widget.scale.clamp(.85, 1.3),
              ),
            ),
            if (details.artist?.trim().isNotEmpty == true) ...[
              const SizedBox(height: 8),
              Text(
                details.artist!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
            if (details.album?.trim().isNotEmpty == true) ...[
              const SizedBox(height: 4),
              Text(
                details.album!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: colors.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              switch (details.playback) {
                MediaPlaybackState.playing => 'Playing',
                MediaPlaybackState.paused => 'Paused',
                MediaPlaybackState.stopped => 'Stopped',
                MediaPlaybackState.error => 'Playback interrupted',
                MediaPlaybackState.seeking => 'Seeking',
                MediaPlaybackState.unknown => 'Playback state unavailable',
              },
              style: Theme.of(context).textTheme.labelMedium
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
          ],
        );
        if (constraints.maxWidth < 300 || textScale >= 1.6) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              metadata,
              if (details.artworkPath != null) ...[
                const SizedBox(height: 16),
                Center(
                  child: MediaArtwork(
                    path: details.artworkPath,
                    size: math.min(128, art),
                  ),
                ),
              ],
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MediaArtwork(path: details.artworkPath, size: art),
            const SizedBox(width: 24),
            Expanded(child: metadata),
          ],
        );
      },
    );
  }

  Widget _progress(MediaDetails details) {
    final duration = details.durationMs;
    final position = details.positionMs;
    final meaningful = duration != null && duration > 0;
    if (position == null && !meaningful) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (meaningful && position != null) ...[
          Semantics(
            label: 'Reported playback position',
            value: '${mediaTime(position)} of ${mediaTime(duration)}',
            child: LinearProgressIndicator(
              key: const ValueKey('media-reported-progress'),
              value: (position / duration).clamp(0, 1),
              minHeight: 4,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 8),
        ],
        Row(
          children: [
            Expanded(child: Text(position == null ? '—' : mediaTime(position))),
            if (meaningful) Text(mediaTime(duration)),
          ],
        ),
      ],
    );
  }

  Widget _controls(MediaSourceState source, bool available) => LayoutBuilder(
    builder: (context, constraints) => Center(
      child: MediaTransportControls(
        source: source,
        busy: !available,
        extent: math.min(
          72 * widget.scale.clamp(1, 1.3),
          constraints.maxWidth / 3,
        ),
        filledPrimary: true,
        onCommand: (command) => _run(
          () => widget.media!.command(source.id, command),
          sourceId: source.id,
        ),
      ),
    ),
  );

  Widget _phone(MediaSourceState source) {
    final session = widget.projectionSnapshot?.sessions
        .where(
          (s) =>
              s.id == source.sessionId &&
              s.device.id == source.deviceId &&
              s.state != ProjectionSessionState.disconnected &&
              s.state != ProjectionSessionState.failed,
        )
        .firstOrNull;
    final phone = source.phone ?? session?.metadata?.phone;
    if (phone == null ||
        phone.batteryPercent == null &&
            phone.charging != true &&
            phone.externalPower != true &&
            phone.criticalBattery != true) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Icon(
            phone.charging == true
                ? Icons.battery_charging_full
                : phone.criticalBattery == true
                ? Icons.battery_alert_outlined
                : Icons.battery_std_outlined,
            size: 18,
          ),
          Text(
            phone.batteryPercent == null
                ? 'Phone'
                : 'Phone battery ${phone.batteryPercent}%',
          ),
          if (phone.charging == true)
            const Text('Charging')
          else if (phone.externalPower == true)
            const Text('Plugged in'),
          if (phone.criticalBattery == true) const Text('Low battery'),
        ],
      ),
    );
  }

  Widget _playbackOptions(MediaDetails details) {
    final playlist = details.playlist?.trim();
    if ((playlist == null || playlist.isEmpty) &&
        details.shuffle == null &&
        details.repeat == null &&
        details.repeatOne != true) {
      return const SizedBox.shrink();
    }
    Widget option(IconData icon, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [Icon(icon, size: 18), const SizedBox(width: 6), Text(label)],
    );
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (playlist != null && playlist.isNotEmpty) ...[
            Text(
              'Playlist · $playlist',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
          ],
          Wrap(
            spacing: 20,
            runSpacing: 12,
            children: [
              if (details.shuffle != null)
                option(
                  Icons.shuffle,
                  details.shuffle! ? 'Shuffle on' : 'Shuffle off',
                ),
              if (details.repeatOne == true)
                option(Icons.repeat_one, 'Repeat one')
              else if (details.repeat != null)
                option(
                  Icons.repeat,
                  details.repeat! ? 'Repeat on' : 'Repeat off',
                ),
            ],
          ),
        ],
      ),
    );
  }
}
