import 'dart:async';

import '../diagnostics/diagnostics_service.dart';
import '../settings/app_setting_keys.dart';
import '../settings/settings_service.dart';
import 'audio_backend.dart';
import 'audio_snapshot.dart';
import 'audio_types.dart';

enum AudioVolumeDirection { down, up }

abstract interface class AudioFocusHandle {
  Future<void> release();
}

abstract interface class AudioService {
  AudioSnapshot get current;
  Stream<AudioSnapshot> get changes;

  Future<void> setMasterVolume(double value);
  Future<void> volumeStep(AudioVolumeDirection direction);
  Future<void> setMuted(bool value);
  Future<void> toggleMuted();
  Future<void> setBalance(double value);
  Future<void> setFader(double value);
  Future<void> setEqualizer(AudioEqualizer value);
  Future<void> selectOutput(String? outputId);
  Future<void> registerSource(AudioSource source);
  Future<void> unregisterSource(String sourceId);
  Future<void> setSourceActive(String sourceId, bool active);
  Future<AudioFocusHandle> requestFocus(String sourceId, {double? duckingGain});
  Future<void> selectNextSource();
  Future<void> selectPreviousSource();
  Future<void> close();
}

/// Backend-neutral audio state, persistence, source focus, and ducking policy.
final class DefaultAudioService implements AudioService {
  DefaultAudioService._({
    required this.backend,
    required this.settings,
    required this.diagnostics,
    required this.volumeStepSize,
    required this.focusPolicy,
    required AudioSnapshot initial,
  }) : _current = initial;

  static Future<DefaultAudioService> start({
    required AudioBackend backend,
    required SettingsService settings,
    required DiagnosticsService diagnostics,
    double volumeStepSize = 0.05,
    AudioFocusPolicy focusPolicy = const AudioFocusPolicy(),
  }) async {
    requireAudioUnit(volumeStepSize, 'volumeStepSize');
    if (volumeStepSize == 0) {
      throw ArgumentError.value(
        volumeStepSize,
        'volumeStepSize',
        'Must be positive',
      );
    }
    focusPolicy.validate();
    try {
      await backend.start();
    } on Object catch (error, stackTrace) {
      try {
        await backend.close();
      } on Object {
        // Preserve the backend startup failure.
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
    final backendState = backend.current;
    final equalizer = AudioEqualizer(
      bassDb: settings.get(AppSettingKeys.audioBassDb),
      midDb: settings.get(AppSettingKeys.audioMidDb),
      trebleDb: settings.get(AppSettingKeys.audioTrebleDb),
    );
    final preferredOutput = settings.get(AppSettingKeys.audioPreferredOutput);
    final service = DefaultAudioService._(
      backend: backend,
      settings: settings,
      diagnostics: diagnostics,
      volumeStepSize: volumeStepSize,
      focusPolicy: focusPolicy,
      initial: AudioSnapshot(
        masterVolume: settings.get(AppSettingKeys.audioMasterVolume),
        muted: settings.get(AppSettingKeys.audioMuted),
        balance: settings.get(AppSettingKeys.audioBalance),
        fader: settings.get(AppSettingKeys.audioFader),
        equalizer: equalizer,
        backendAvailable: backendState.available,
        capabilities: backendState.capabilities,
        selectedOutput: preferredOutput.isEmpty
            ? backendState.selectedOutput
            : preferredOutput,
        activeSources: const [],
        effectiveSourceGains: const {},
        focusSources: const [],
      ),
    );
    try {
      await service._restoreBackend();
      service._backendSubscription = backend.changes.listen(
        service._onBackendChanged,
        onError: (Object error, StackTrace stackTrace) {
          diagnostics.error(
            'audio.backend',
            'Audio backend state observation failed.',
            error: error,
            stackTrace: stackTrace,
          );
        },
      );
      return service;
    } on Object catch (error, stackTrace) {
      try {
        await backend.close();
      } on Object {
        // Preserve startup failure.
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  final AudioBackend backend;
  final SettingsService settings;
  final DiagnosticsService diagnostics;
  final double volumeStepSize;
  final AudioFocusPolicy focusPolicy;
  final _changes = StreamController<AudioSnapshot>.broadcast(sync: true);
  final Map<String, AudioSource> _sources = {};
  final Set<String> _activeSources = {};
  final Map<int, _FocusRequest> _focusRequests = {};
  Future<void> _operationTail = Future.value();
  StreamSubscription<AudioBackendState>? _backendSubscription;
  late AudioSnapshot _current;
  var _nextFocusId = 1;
  var _closed = false;

  @override
  AudioSnapshot get current => _current;
  @override
  Stream<AudioSnapshot> get changes => _changes.stream;

  Future<void> _restoreBackend() async {
    if (!backend.current.available) return;
    final capabilities = backend.current.capabilities;
    if (capabilities.masterVolume) {
      await backend.setMasterVolume(_current.masterVolume);
    }
    if (capabilities.mute) await backend.setMuted(_current.muted);
    if (capabilities.balance || capabilities.fader) {
      await backend.setChannelGains(_channelGains());
    }
    if (capabilities.equalizer) {
      await backend.setEqualizer(_current.equalizer);
    }
    if (capabilities.outputSelection && _current.selectedOutput != null) {
      await backend.selectOutput(_current.selectedOutput);
    }
  }

  @override
  Future<void> setMasterVolume(double value) {
    requireAudioUnit(value, 'value');
    return _serialize(() => _applyMasterVolume(value));
  }

  @override
  Future<void> volumeStep(AudioVolumeDirection direction) =>
      _serialize(() async {
        final stepped =
            (_current.masterVolume +
                    (direction == AudioVolumeDirection.up
                        ? volumeStepSize
                        : -volumeStepSize))
                .clamp(0.0, 1.0);
        final value = (stepped * 1000000).round() / 1000000;
        await _applyMasterVolume(value);
      });

  Future<void> _applyMasterVolume(double value) async {
    if (_current.masterVolume == value) return;
    if (backend.current.available &&
        backend.current.capabilities.masterVolume) {
      await backend.setMasterVolume(value);
    }
    _replace(masterVolume: value);
    await settings.set(AppSettingKeys.audioMasterVolume, value);
  }

  @override
  Future<void> setMuted(bool value) => _serialize(() async {
    if (_current.muted == value) return;
    if (backend.current.available && backend.current.capabilities.mute) {
      await backend.setMuted(value);
    }
    _replace(muted: value);
    await settings.set(AppSettingKeys.audioMuted, value);
  });

  @override
  Future<void> toggleMuted() => _serialize(() async {
    final value = !_current.muted;
    if (backend.current.available && backend.current.capabilities.mute) {
      await backend.setMuted(value);
    }
    _replace(muted: value);
    await settings.set(AppSettingKeys.audioMuted, value);
  });

  @override
  Future<void> setBalance(double value) {
    requireAudioSignedUnit(value, 'value');
    return _serialize(() async {
      if (_current.balance == value) return;
      if (backend.current.available && !backend.current.capabilities.balance) {
        throw UnsupportedAudioFeatureException('balance');
      }
      if (backend.current.available) {
        await backend.setChannelGains(_channelGains(balance: value));
      }
      _replace(balance: value);
      await settings.set(AppSettingKeys.audioBalance, value);
    });
  }

  @override
  Future<void> setFader(double value) {
    requireAudioSignedUnit(value, 'value');
    return _serialize(() async {
      if (_current.fader == value) return;
      if (backend.current.available && !backend.current.capabilities.fader) {
        throw UnsupportedAudioFeatureException('fader');
      }
      if (backend.current.available) {
        await backend.setChannelGains(_channelGains(fader: value));
      }
      _replace(fader: value);
      await settings.set(AppSettingKeys.audioFader, value);
    });
  }

  @override
  Future<void> setEqualizer(AudioEqualizer value) {
    value.validate();
    return _serialize(() async {
      if (_current.equalizer == value) return;
      if (backend.current.available &&
          !backend.current.capabilities.equalizer) {
        throw UnsupportedAudioFeatureException('equalizer');
      }
      if (backend.current.available) await backend.setEqualizer(value);
      _replace(equalizer: value);
      await Future.wait([
        settings.set(AppSettingKeys.audioBassDb, value.bassDb),
        settings.set(AppSettingKeys.audioMidDb, value.midDb),
        settings.set(AppSettingKeys.audioTrebleDb, value.trebleDb),
      ]);
    });
  }

  @override
  Future<void> selectOutput(String? outputId) => _serialize(() async {
    final normalized = outputId?.trim();
    if (normalized != null && normalized.isEmpty) {
      throw ArgumentError.value(outputId, 'outputId', 'Must not be empty');
    }
    if (_current.selectedOutput == normalized) return;
    if (backend.current.available &&
        !backend.current.capabilities.outputSelection) {
      throw UnsupportedAudioFeatureException('output selection');
    }
    if (backend.current.available) await backend.selectOutput(normalized);
    _replace(selectedOutput: normalized, replaceOutput: true);
    await settings.set(AppSettingKeys.audioPreferredOutput, normalized ?? '');
  });

  @override
  Future<void> registerSource(AudioSource source) => _serialize(() async {
    if (_sources.containsKey(source.id)) {
      throw StateError('Audio source "${source.id}" is already registered.');
    }
    _sources[source.id] = source;
    _replace();
  });

  @override
  Future<void> unregisterSource(String sourceId) => _serialize(() async {
    if (backend.current.available &&
        backend.current.capabilities.perSourceRouting &&
        _sources.containsKey(sourceId)) {
      await backend.setSourceGain(sourceId, 0);
    }
    _sources.remove(sourceId);
    _activeSources.remove(sourceId);
    _focusRequests.removeWhere((_, request) => request.sourceId == sourceId);
    if (_current.selectedSource == sourceId) {
      _replace(selectedSource: null, replaceSelectedSource: true);
    }
    await _recomputeSourceGains();
  });

  @override
  Future<void> setSourceActive(String sourceId, bool active) =>
      _serialize(() async {
        _requireSource(sourceId);
        active ? _activeSources.add(sourceId) : _activeSources.remove(sourceId);
        await _recomputeSourceGains();
      });

  @override
  Future<AudioFocusHandle> requestFocus(
    String sourceId, {
    double? duckingGain,
  }) async {
    final source = _requireSource(sourceId);
    final gain = duckingGain ?? focusPolicy.gainFor(source.role);
    requireAudioUnit(gain, 'duckingGain');
    final id = _nextFocusId++;
    await _serialize(() async {
      _focusRequests[id] = _FocusRequest(sourceId, source.role, gain);
      await _recomputeSourceGains();
    });
    return _DefaultAudioFocusHandle(() => _releaseFocus(id));
  }

  Future<void> _releaseFocus(int id) => _serialize(() async {
    if (_focusRequests.remove(id) == null) return;
    await _recomputeSourceGains();
  });

  @override
  Future<void> selectNextSource() => _selectRelative(1);
  @override
  Future<void> selectPreviousSource() => _selectRelative(-1);

  Future<void> _selectRelative(int delta) => _serialize(() async {
    if (_sources.isEmpty) return;
    final ids = _sources.keys.toList(growable: false);
    final currentIndex = _current.selectedSource == null
        ? (delta > 0 ? -1 : 0)
        : ids.indexOf(_current.selectedSource!);
    final next = (currentIndex + delta) % ids.length;
    _replace(selectedSource: ids[next], replaceSelectedSource: true);
  });

  Future<void> _recomputeSourceGains() async {
    final gains = <String, double>{};
    for (final entry in _sources.entries) {
      final sourceId = entry.key;
      final source = entry.value;
      var gain = _activeSources.contains(sourceId) ? source.gain : 0.0;
      for (final request in _focusRequests.values) {
        if (request.sourceId == sourceId ||
            _priority(request.role) <= _priority(source.role)) {
          continue;
        }
        gain *= request.duckingGain;
      }
      gains[sourceId] = gain.clamp(0.0, 1.0);
    }
    if (backend.current.available &&
        backend.current.capabilities.perSourceRouting) {
      for (final entry in gains.entries) {
        await backend.setSourceGain(entry.key, entry.value);
      }
    }
    _replace(effectiveSourceGains: gains);
  }

  static int _priority(AudioSourceRole role) => switch (role) {
    AudioSourceRole.media => 0,
    AudioSourceRole.navigation => 1,
    AudioSourceRole.system => 2,
    AudioSourceRole.communication => 3,
  };

  Map<AudioChannelPosition, double> _channelGains({
    double? balance,
    double? fader,
  }) {
    balance ??= _current.balance;
    fader ??= _current.fader;
    final left = balance > 0 ? 1 - balance : 1.0;
    final right = balance < 0 ? 1 + balance : 1.0;
    final front = fader < 0 ? 1 + fader : 1.0;
    final rear = fader > 0 ? 1 - fader : 1.0;
    final channels = backend.current.channels;
    return {
      if (channels.contains(AudioChannelPosition.left))
        AudioChannelPosition.left: left,
      if (channels.contains(AudioChannelPosition.right))
        AudioChannelPosition.right: right,
      if (channels.contains(AudioChannelPosition.frontLeft))
        AudioChannelPosition.frontLeft: left * front,
      if (channels.contains(AudioChannelPosition.frontRight))
        AudioChannelPosition.frontRight: right * front,
      if (channels.contains(AudioChannelPosition.rearLeft))
        AudioChannelPosition.rearLeft: left * rear,
      if (channels.contains(AudioChannelPosition.rearRight))
        AudioChannelPosition.rearRight: right * rear,
    };
  }

  AudioSource _requireSource(String id) {
    final source = _sources[id];
    if (source == null) {
      throw StateError('Audio source "$id" is not registered.');
    }
    return source;
  }

  void _onBackendChanged(AudioBackendState state) {
    if (_closed) return;
    _replace(
      masterVolume: state.masterVolume,
      muted: state.muted,
      backendAvailable: state.available,
      capabilities: state.capabilities,
      selectedOutput: state.selectedOutput,
      replaceOutput: true,
    );
  }

  void _replace({
    double? masterVolume,
    bool? muted,
    double? balance,
    double? fader,
    AudioEqualizer? equalizer,
    bool? backendAvailable,
    AudioBackendCapabilities? capabilities,
    String? selectedOutput,
    bool replaceOutput = false,
    Map<String, double>? effectiveSourceGains,
    String? selectedSource,
    bool replaceSelectedSource = false,
  }) {
    final next = AudioSnapshot(
      masterVolume: masterVolume ?? _current.masterVolume,
      muted: muted ?? _current.muted,
      balance: balance ?? _current.balance,
      fader: fader ?? _current.fader,
      equalizer: equalizer ?? _current.equalizer,
      backendAvailable: backendAvailable ?? _current.backendAvailable,
      capabilities: capabilities ?? _current.capabilities,
      selectedOutput: replaceOutput ? selectedOutput : _current.selectedOutput,
      activeSources: _activeSources,
      effectiveSourceGains:
          effectiveSourceGains ?? _current.effectiveSourceGains,
      focusSources: _focusRequests.values.map((request) => request.sourceId),
      selectedSource: replaceSelectedSource
          ? selectedSource
          : _current.selectedSource,
    );
    if (next == _current) return;
    _current = next;
    _changes.add(next);
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    if (_closed) return Future.error(StateError('Audio service is closed.'));
    final completer = Completer<T>();
    _operationTail = _operationTail.then((_) async {
      try {
        completer.complete(await operation());
      } on Object catch (error, stackTrace) {
        diagnostics.error(
          'audio.service',
          'Audio operation failed.',
          error: error,
          stackTrace: stackTrace,
        );
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _operationTail;
    await _backendSubscription?.cancel();
    await backend.close();
    // Flutter may still be subscribed while an application-exit request is
    // awaiting lifecycle cleanup. Initiate stream closure without making
    // resource shutdown depend on widget disposal order.
    unawaited(_changes.close());
  }
}

final class _FocusRequest {
  const _FocusRequest(this.sourceId, this.role, this.duckingGain);
  final String sourceId;
  final AudioSourceRole role;
  final double duckingGain;
}

final class _DefaultAudioFocusHandle implements AudioFocusHandle {
  _DefaultAudioFocusHandle(this._release);
  final Future<void> Function() _release;
  Future<void>? _future;

  @override
  Future<void> release() => _future ??= _release();
}
