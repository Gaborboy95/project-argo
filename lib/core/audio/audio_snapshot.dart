import 'dart:collection';

import 'audio_types.dart';

final class AudioSnapshot {
  AudioSnapshot({
    required this.masterVolume,
    required this.muted,
    required this.balance,
    required this.fader,
    required this.equalizer,
    required this.backendAvailable,
    required this.capabilities,
    required this.selectedOutput,
    required Iterable<String> activeSources,
    required Map<String, double> effectiveSourceGains,
    required Iterable<String> focusSources,
    this.selectedSource,
  }) : activeSources = UnmodifiableSetView(Set.of(activeSources)),
       effectiveSourceGains = Map.unmodifiable(effectiveSourceGains),
       focusSources = UnmodifiableSetView(Set.of(focusSources));

  final double masterVolume;
  final bool muted;
  final double balance;
  final double fader;
  final AudioEqualizer equalizer;
  final bool backendAvailable;
  final AudioBackendCapabilities capabilities;
  final String? selectedOutput;
  final Set<String> activeSources;
  final Map<String, double> effectiveSourceGains;
  final Set<String> focusSources;
  final String? selectedSource;

  @override
  bool operator ==(Object other) =>
      other is AudioSnapshot &&
      masterVolume == other.masterVolume &&
      muted == other.muted &&
      balance == other.balance &&
      fader == other.fader &&
      equalizer == other.equalizer &&
      backendAvailable == other.backendAvailable &&
      capabilities == other.capabilities &&
      selectedOutput == other.selectedOutput &&
      selectedSource == other.selectedSource &&
      _setEquals(activeSources, other.activeSources) &&
      _mapEquals(effectiveSourceGains, other.effectiveSourceGains) &&
      _setEquals(focusSources, other.focusSources);

  @override
  int get hashCode => Object.hash(
    masterVolume,
    muted,
    balance,
    fader,
    equalizer,
    backendAvailable,
    capabilities,
    selectedOutput,
    selectedSource,
    Object.hashAllUnordered(activeSources),
    Object.hashAllUnordered(
      effectiveSourceGains.entries.map(
        (entry) => Object.hash(entry.key, entry.value),
      ),
    ),
    Object.hashAllUnordered(focusSources),
  );
}

bool _setEquals<T>(Set<T> left, Set<T> right) =>
    left.length == right.length && left.containsAll(right);

bool _mapEquals<K, V>(Map<K, V> left, Map<K, V> right) =>
    left.length == right.length &&
    left.entries.every((entry) => right[entry.key] == entry.value);
