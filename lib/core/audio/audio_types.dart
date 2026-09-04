import 'dart:collection';

enum AudioChannelPosition {
  frontLeft,
  frontRight,
  rearLeft,
  rearRight,
  left,
  right,
  unknown,
}

enum AudioSourceRole { media, navigation, communication, system }

final class AudioSource {
  AudioSource({required this.id, required this.role, this.gain = 1.0}) {
    if (!_idPattern.hasMatch(id)) {
      throw ArgumentError.value(id, 'id', 'Invalid stable audio source ID');
    }
    _requireUnit(gain, 'gain');
  }

  static final _idPattern = RegExp(
    r'^[a-z0-9][a-z0-9_-]*(?:\.[a-z0-9][a-z0-9_-]*)*$',
  );

  final String id;
  final AudioSourceRole role;
  final double gain;
}

final class AudioFocusPolicy {
  const AudioFocusPolicy({
    this.navigationDuckingGain = 0.35,
    this.communicationDuckingGain = 0.15,
    this.systemDuckingGain = 0.5,
  });

  final double navigationDuckingGain;
  final double communicationDuckingGain;
  final double systemDuckingGain;

  double gainFor(AudioSourceRole role) => switch (role) {
    AudioSourceRole.media => 1,
    AudioSourceRole.navigation => navigationDuckingGain,
    AudioSourceRole.communication => communicationDuckingGain,
    AudioSourceRole.system => systemDuckingGain,
  };

  void validate() {
    _requireUnit(navigationDuckingGain, 'navigationDuckingGain');
    _requireUnit(communicationDuckingGain, 'communicationDuckingGain');
    _requireUnit(systemDuckingGain, 'systemDuckingGain');
  }
}

final class AudioBackendCapabilities {
  const AudioBackendCapabilities({
    this.masterVolume = false,
    this.mute = false,
    this.balance = false,
    this.fader = false,
    this.equalizer = false,
    this.outputSelection = false,
    this.perSourceRouting = false,
  });

  final bool masterVolume;
  final bool mute;
  final bool balance;
  final bool fader;
  final bool equalizer;
  final bool outputSelection;
  final bool perSourceRouting;

  @override
  bool operator ==(Object other) =>
      other is AudioBackendCapabilities &&
      masterVolume == other.masterVolume &&
      mute == other.mute &&
      balance == other.balance &&
      fader == other.fader &&
      equalizer == other.equalizer &&
      outputSelection == other.outputSelection &&
      perSourceRouting == other.perSourceRouting;

  @override
  int get hashCode => Object.hash(
    masterVolume,
    mute,
    balance,
    fader,
    equalizer,
    outputSelection,
    perSourceRouting,
  );
}

final class AudioBackendState {
  AudioBackendState({
    required this.available,
    required this.capabilities,
    required this.masterVolume,
    required this.muted,
    this.selectedOutput,
    Iterable<AudioChannelPosition> channels = const [],
  }) : channels = UnmodifiableSetView(Set.of(channels)) {
    _requireUnit(masterVolume, 'masterVolume');
  }

  final bool available;
  final AudioBackendCapabilities capabilities;
  final double masterVolume;
  final bool muted;
  final String? selectedOutput;
  final Set<AudioChannelPosition> channels;
}

final class AudioEqualizer {
  const AudioEqualizer({this.bassDb = 0, this.midDb = 0, this.trebleDb = 0});

  static const double minimumDb = -12;
  static const double maximumDb = 12;

  final double bassDb;
  final double midDb;
  final double trebleDb;

  AudioEqualizer copyWith({double? bassDb, double? midDb, double? trebleDb}) =>
      AudioEqualizer(
        bassDb: bassDb ?? this.bassDb,
        midDb: midDb ?? this.midDb,
        trebleDb: trebleDb ?? this.trebleDb,
      );

  void validate() {
    _requireRange(bassDb, minimumDb, maximumDb, 'bassDb');
    _requireRange(midDb, minimumDb, maximumDb, 'midDb');
    _requireRange(trebleDb, minimumDb, maximumDb, 'trebleDb');
  }

  @override
  bool operator ==(Object other) =>
      other is AudioEqualizer &&
      bassDb == other.bassDb &&
      midDb == other.midDb &&
      trebleDb == other.trebleDb;

  @override
  int get hashCode => Object.hash(bassDb, midDb, trebleDb);
}

void requireAudioUnit(double value, String name) => _requireUnit(value, name);

void requireAudioSignedUnit(double value, String name) =>
    _requireRange(value, -1, 1, name);

void requireAudioEq(double value, String name) => _requireRange(
  value,
  AudioEqualizer.minimumDb,
  AudioEqualizer.maximumDb,
  name,
);

void _requireUnit(double value, String name) =>
    _requireRange(value, 0, 1, name);

void _requireRange(double value, double minimum, double maximum, String name) {
  if (!value.isFinite || value < minimum || value > maximum) {
    throw RangeError.value(
      value,
      name,
      'Must be finite and within $minimum..$maximum',
    );
  }
}
