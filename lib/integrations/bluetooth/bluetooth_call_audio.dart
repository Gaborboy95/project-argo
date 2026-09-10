import 'dart:async';

import '../../core/audio/audio_service.dart';
import '../../core/audio/audio_types.dart';
import '../../core/connectivity/connectivity_service.dart';

/// Calls hold communication focus without selecting a different media provider.
final class BluetoothCallAudio {
  BluetoothCallAudio(this.connectivity, this.audio) {
    _tail = audio.registerSource(
      AudioSource(id: _id, role: AudioSourceRole.communication),
    );
    _subscription = connectivity.connectivityChanges.listen(_update);
    _update(connectivity.connectivity);
  }
  static const _id = 'bluetooth.call';
  final ConnectivityService connectivity;
  final AudioService audio;
  StreamSubscription<ConnectivitySnapshot>? _subscription;
  Future<void> _tail = Future.value();
  AudioFocusHandle? _focus;
  bool _active = false;
  void _update(ConnectivitySnapshot state) {
    final active = ((state.calls?['calls'] as List?) ?? []).any(
      (c) => [
        'incoming',
        'waiting',
        'dialing',
        'alerting',
        'active',
      ].contains(c['state']),
    );
    if (active == _active) return;
    _active = active;
    _tail = _tail
        .then((_) async {
          await audio.setSourceActive(_id, active);
          if (active) {
            _focus ??= await audio.requestFocus(_id);
          } else {
            await _focus?.release();
            _focus = null;
          }
        })
        .catchError((Object _) {});
  }

  Future<void> close() async {
    await _subscription?.cancel();
    await _tail;
    await _focus?.release();
    await audio.unregisterSource(_id);
  }
}
