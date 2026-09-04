import 'dart:async';

import 'audio_types.dart';

abstract interface class AudioBackend {
  AudioBackendState get current;
  Stream<AudioBackendState> get changes;

  Future<void> start();
  Future<void> setMasterVolume(double value);
  Future<void> setMuted(bool value);

  /// Applies per-channel multipliers after master volume. Every gain is 0..1.
  Future<void> setChannelGains(Map<AudioChannelPosition, double> gains);
  Future<void> setEqualizer(AudioEqualizer equalizer);
  Future<void> selectOutput(String? outputId);
  Future<void> setSourceGain(String sourceId, double gain);
  Future<void> close();
}

final class UnsupportedAudioFeatureException extends UnsupportedError {
  UnsupportedAudioFeatureException(String feature)
    : super('The active audio backend does not support $feature.');
}

final class DisabledAudioBackend implements AudioBackend {
  const DisabledAudioBackend();

  static final AudioBackendState _state = AudioBackendState(
    available: false,
    capabilities: const AudioBackendCapabilities(),
    masterVolume: 0.5,
    muted: false,
  );

  @override
  AudioBackendState get current => _state;

  @override
  Stream<AudioBackendState> get changes => const Stream.empty();

  @override
  Future<void> start() async {}
  @override
  Future<void> setMasterVolume(double value) async {}
  @override
  Future<void> setMuted(bool value) async {}
  @override
  Future<void> setChannelGains(Map<AudioChannelPosition, double> gains) async {}
  @override
  Future<void> setEqualizer(AudioEqualizer equalizer) async {}
  @override
  Future<void> selectOutput(String? outputId) async {}
  @override
  Future<void> setSourceGain(String sourceId, double gain) async {}
  @override
  Future<void> close() async {}
}
