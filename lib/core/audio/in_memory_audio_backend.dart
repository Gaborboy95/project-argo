import 'dart:async';

import 'audio_backend.dart';
import 'audio_types.dart';

/// Deterministic host-free backend for service and feature tests.
final class InMemoryAudioBackend implements AudioBackend {
  InMemoryAudioBackend({
    Iterable<AudioChannelPosition> channels = const [
      AudioChannelPosition.left,
      AudioChannelPosition.right,
    ],
    bool available = true,
    bool equalizer = true,
    bool outputSelection = true,
    bool perSourceRouting = true,
  }) {
    final channelSet = Set.of(channels);
    final hasLeftRight =
        (channelSet.contains(AudioChannelPosition.left) &&
            channelSet.contains(AudioChannelPosition.right)) ||
        (channelSet.contains(AudioChannelPosition.frontLeft) &&
            channelSet.contains(AudioChannelPosition.frontRight));
    final hasFrontRear =
        channelSet.contains(AudioChannelPosition.frontLeft) &&
        channelSet.contains(AudioChannelPosition.frontRight) &&
        channelSet.contains(AudioChannelPosition.rearLeft) &&
        channelSet.contains(AudioChannelPosition.rearRight);
    _state = AudioBackendState(
      available: available,
      capabilities: AudioBackendCapabilities(
        masterVolume: true,
        mute: true,
        balance: hasLeftRight,
        fader: hasFrontRear,
        equalizer: equalizer,
        outputSelection: outputSelection,
        perSourceRouting: perSourceRouting,
      ),
      masterVolume: 0.5,
      muted: false,
      selectedOutput: 'memory.default',
      channels: channelSet,
    );
  }

  late AudioBackendState _state;
  final _changes = StreamController<AudioBackendState>.broadcast(sync: true);
  Map<AudioChannelPosition, double> channelGains = const {};
  AudioEqualizer equalizer = const AudioEqualizer();
  final Map<String, double> sourceGains = {};
  var isClosed = false;

  @override
  AudioBackendState get current => _state;
  @override
  Stream<AudioBackendState> get changes => _changes.stream;
  @override
  Future<void> start() async {}

  @override
  Future<void> setMasterVolume(double value) async {
    requireAudioUnit(value, 'value');
    _replace(masterVolume: value);
  }

  @override
  Future<void> setMuted(bool value) async => _replace(muted: value);

  @override
  Future<void> setChannelGains(Map<AudioChannelPosition, double> gains) async {
    for (final entry in gains.entries) {
      requireAudioUnit(entry.value, entry.key.name);
    }
    channelGains = Map.unmodifiable(gains);
  }

  @override
  Future<void> setEqualizer(AudioEqualizer value) async {
    value.validate();
    equalizer = value;
  }

  @override
  Future<void> selectOutput(String? outputId) async =>
      _replace(selectedOutput: outputId, replaceOutput: true);

  @override
  Future<void> setSourceGain(String sourceId, double gain) async {
    requireAudioUnit(gain, 'gain');
    sourceGains[sourceId] = gain;
  }

  @override
  Future<void> close() async {
    if (isClosed) return;
    isClosed = true;
    await _changes.close();
  }

  void _replace({
    double? masterVolume,
    bool? muted,
    String? selectedOutput,
    bool replaceOutput = false,
  }) {
    _state = AudioBackendState(
      available: _state.available,
      capabilities: _state.capabilities,
      masterVolume: masterVolume ?? _state.masterVolume,
      muted: muted ?? _state.muted,
      selectedOutput: replaceOutput ? selectedOutput : _state.selectedOutput,
      channels: _state.channels,
    );
    _changes.add(_state);
  }
}
