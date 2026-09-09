import '../../core/audio/audio_service.dart';
import '../../core/audio/audio_types.dart';

import 'dart:async';

import '../../core/connectivity/connectivity_service.dart';
import '../../core/media/media_session_service.dart';
import '../../core/media/media_state.dart';

/// Adapts daemon facts/acknowledgements. BlueZ objects and PCM stay in Linux.
final class BluetoothMediaSource {
  BluetoothMediaSource(this.connectivity, this.media, {this.audio}) {
    _provider = media.register('bluetooth');
    _audioTail =
        audio?.registerSource(
          AudioSource(id: 'bluetooth.music', role: AudioSourceRole.media),
        ) ??
        Future.value();
    _audioSubscription = audio?.changes.listen((_) => _sendGain());
    _subscription = connectivity.connectivityChanges.listen(_update);
    media.select = (source) => request(
      'musicSelect',
      target: switch (source.kind) {
        MediaSourceKind.bluetooth => source.id,
        MediaSourceKind.androidAuto => 'projection',
        _ => throw UnsupportedError(
          'This media provider has no implemented audio routing',
        ),
      },
    );
    media.execute = (source, command) => request(
      'music${command[0].toUpperCase()}${command.substring(1)}',
      target: source.id,
    );
    _update(connectivity.connectivity);
  }
  final ConnectivityService connectivity;
  final AudioService? audio;
  StreamSubscription<Object?>? _audioSubscription;
  Future<void> _audioTail = Future.value();
  String? _sentGain;
  void _sendGain() {
    final source =
        connectivity.connectivity.music?['source'] as Map<String, dynamic>?;
    if (source == null || audio == null) return;
    final target =
        '${source['id']}|${audio!.current.effectiveSourceGains['bluetooth.music'] ?? 0}';
    if (_sentGain == target) return;
    _sentGain = target;
    unawaited(
      connectivity.connectivityCommand('musicGain', target: target).catchError((
        Object _,
      ) {
        _sentGain = null;
      }),
    );
  }

  final CachedMediaSessionService media;
  late final MediaProvider _provider;
  late final StreamSubscription<ConnectivitySnapshot> _subscription;
  int _revision = 0, _operation = DateTime.now().millisecondsSinceEpoch;
  Future<void> request(String action, {String target = ''}) async {
    if (connectivity.connectivity.music == null) {
      throw StateError('Bluetooth/media controller unavailable in this daemon');
    }
    final operation = ++_operation;
    final done = Completer<void>();
    final subscription = connectivity.connectivityChanges.listen((s) {
      if (s.music?['operation'] != operation || done.isCompleted) return;
      final error = s.music?['error'];
      if (error is String) {
        done.completeError(StateError(error));
      } else {
        done.complete();
      }
    });
    try {
      await connectivity.connectivityCommand(
        action,
        target: target,
        prompt: operation,
      );
      await done.future.timeout(const Duration(seconds: 20));
    } finally {
      await subscription.cancel();
    }
  }

  void _update(ConnectivitySnapshot snapshot) {
    final music = snapshot.music;
    final source = music?['source'] as Map<String, dynamic>?;
    final sources = <MediaSourceState>[];
    if (source != null) {
      final state = source['playback'];
      sources.add(
        MediaSourceState(
          id: source['id'] as String,
          kind: MediaSourceKind.bluetooth,
          deviceId: source['device_id'] as String,
          sessionId: source['session_id'] as String,
          revision: source['revision'] as int,
          updatedAtMs: source['updated_at_ms'] as int,
          displayName: source['name'] as String?,
          commands: (source['commands'] as List).cast<String>(),
          details: MediaDetails(
            title: source['title'] as String?,
            artist: source['artist'] as String?,
            album: source['album'] as String?,
            artworkPath: source['artwork_path'] as String?,
            playback:
                MediaPlaybackState.values
                    .where((s) => s.name == state)
                    .firstOrNull ??
                MediaPlaybackState.unknown,
            positionMs: source['position_ms'] as int?,
            durationMs: source['duration_ms'] as int?,
          ),
        ),
      );
    }
    _provider.publish(++_revision, sources);
    if (audio != null) {
      _audioTail = _audioTail
          .then((_) async {
            await audio!.setSourceActive(
              'bluetooth.music',
              connectivity.connectivity.music?['selected'] == 'bluetooth' &&
                  connectivity.connectivity.music?['source'] != null,
            );
            _sendGain();
          })
          .catchError((Object _) {});
    }
    if (music != null) {
      final selected = music['selected'];
      media.reflectSelection(
        selected == 'bluetooth'
            ? (source?['id'] as String?)
            : selected == 'projection'
            ? media.current.sources
                  .where(
                    (s) =>
                        s.kind == MediaSourceKind.androidAuto ||
                        s.kind == MediaSourceKind.carPlay,
                  )
                  .firstOrNull
                  ?.id
            : null,
      );
    }
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _audioSubscription?.cancel();
    await _audioTail;
    await audio?.unregisterSource('bluetooth.music');
    _provider.close();
  }
}
