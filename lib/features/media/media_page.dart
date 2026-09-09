import '../../core/connectivity/connectivity_service.dart';
import '../../core/media/media_session_service.dart';
import '../../core/media/media_state.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/projection/projection_models.dart';
import '../../core/projection/projection_service.dart';
import '../../core/projection/projection_types.dart';

class MediaPage extends StatefulWidget {
  const MediaPage({
    super.key,
    required this.projection,
    this.media,
    this.connectivity,
  });

  final ProjectionService projection;
  final MediaSessionService? media;
  final ConnectivityService? connectivity;

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
        if (widget.connectivity != null)
          _MusicConnection(service: widget.connectivity!),
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
            if (media != null && media!.current.sources.isNotEmpty)
              DropdownButton<String>(
                value: media!.current.activeSourceId,
                hint: const Text('Select entertainment source'),
                isExpanded: true,
                items: [
                  for (final s in media!.current.sources)
                    DropdownMenuItem(
                      value: s.id,
                      child: Text(
                        '${s.kind.name} · ${s.displayName ?? s.details.application ?? "Phone"}',
                      ),
                    ),
                ],
                onChanged: (id) {
                  if (id != null) {
                    _action(context, () => media!.selectSource(id));
                  }
                },
              ),
            if (source != null && source.commands.isNotEmpty)
              Wrap(
                spacing: 8,
                children: [
                  for (final command in source.commands)
                    OutlinedButton(
                      onPressed: () => _action(
                        context,
                        () => media!.command(source.id, command),
                      ),
                      child: Text(command),
                    ),
                ],
              ),
            Text(
              source?.kind == MediaSourceKind.bluetooth
                  ? 'Bluetooth · ${source?.displayName ?? "Phone"}'
                  : live
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

void _action(BuildContext context, Future<void> Function() action) {
  unawaited(
    action().catchError((Object error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }),
  );
}

class _MusicConnection extends StatefulWidget {
  const _MusicConnection({required this.service});
  final ConnectivityService service;
  @override
  State<_MusicConnection> createState() => _MusicConnectionState();
}

class _MusicConnectionState extends State<_MusicConnection> {
  String? _phone;
  @override
  Widget build(BuildContext context) => StreamBuilder<ConnectivitySnapshot>(
    stream: widget.service.connectivityChanges,
    builder: (context, _) {
      final state = widget.service.connectivity;
      if (state.music == null) return const SizedBox.shrink();
      final phones = state.devices
          .where((d) => d.paired && d.id.startsWith('${state.adapter}/'))
          .toList();
      final selected = phones.any((d) => d.id == _phone)
          ? _phone
          : phones.where((d) => d.id == state.music?['device']).firstOrNull?.id;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButton<String>(
            value: selected,
            hint: const Text('Select paired music phone'),
            isExpanded: true,
            items: [
              for (final d in phones)
                DropdownMenuItem(value: d.id, child: Text(d.name)),
            ],
            onChanged: (value) => setState(() => _phone = value),
          ),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton(
                onPressed: selected == null
                    ? null
                    : () => _action(
                        context,
                        () => widget.service.connectivityCommand(
                          'musicConnect',
                          target: selected,
                        ),
                      ),
                child: const Text('Connect music'),
              ),
              OutlinedButton(
                onPressed: () => _action(
                  context,
                  () => widget.service.connectivityCommand('musicDisconnect'),
                ),
                child: const Text('Disconnect music'),
              ),
            ],
          ),
          Text(
            '${state.music?['phase'] ?? ""} · ${state.music?['error'] ?? state.music?['detail'] ?? ""}',
          ),
          if (state.music?['cleanup_error'] != null)
            Text('Cleanup: ${state.music?["cleanup_error"]}'),
          const SizedBox(height: 12),
        ],
      );
    },
  );
}
