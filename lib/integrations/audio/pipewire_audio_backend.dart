import 'dart:async';
import 'dart:io';

import '../../core/audio/audio_backend.dart';
import '../../core/audio/audio_types.dart';

typedef AudioProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

/// Low-frequency WirePlumber control for the true default system output.
///
/// PCM stays entirely in PipeWire. `wpctl` is invoked directly, never through
/// a shell, and only with operations selected by this class.
final class PipeWireAudioBackend implements AudioBackend {
  PipeWireAudioBackend({AudioProcessRunner? processRunner})
    : _processRunner = processRunner ?? _runProcess;

  static const _sink = '@DEFAULT_AUDIO_SINK@';
  final AudioProcessRunner _processRunner;
  final _changes = StreamController<AudioBackendState>.broadcast(sync: true);
  AudioBackendState _state = AudioBackendState(
    available: false,
    capabilities: const AudioBackendCapabilities(),
    masterVolume: 0.5,
    muted: false,
  );
  var _closed = false;

  @override
  AudioBackendState get current => _state;
  @override
  Stream<AudioBackendState> get changes => _changes.stream;

  @override
  Future<void> start() async {
    _ensureOpen();
    final volumeResult = await _run('get-volume', [_sink]);
    final parsed = _parseVolume(volumeResult.stdout.toString());
    final inspectResult = await _run('inspect', [_sink]);
    final channels = _parseChannels(inspectResult.stdout.toString());
    _state = AudioBackendState(
      available: true,
      capabilities: const AudioBackendCapabilities(
        masterVolume: true,
        mute: true,
      ),
      masterVolume: parsed.volume,
      muted: parsed.muted,
      selectedOutput: _sink,
      channels: channels,
    );
    _changes.add(_state);
  }

  @override
  Future<void> setMasterVolume(double value) async {
    requireAudioUnit(value, 'value');
    await _run('set-volume', [
      _sink,
      value.toStringAsFixed(6),
      '--limit',
      '1.0',
    ]);
    _replace(masterVolume: value);
  }

  @override
  Future<void> setMuted(bool value) async {
    await _run('set-mute', [_sink, value ? '1' : '0']);
    _replace(muted: value);
  }

  @override
  Future<void> setChannelGains(Map<AudioChannelPosition, double> gains) =>
      Future.error(UnsupportedAudioFeatureException('channel gain control'));

  @override
  Future<void> setEqualizer(AudioEqualizer equalizer) =>
      Future.error(UnsupportedAudioFeatureException('equalizer'));

  @override
  Future<void> selectOutput(String? outputId) =>
      Future.error(UnsupportedAudioFeatureException('output selection'));

  @override
  Future<void> setSourceGain(String sourceId, double gain) =>
      Future.error(UnsupportedAudioFeatureException('per-source routing'));

  Future<ProcessResult> _run(String operation, List<String> arguments) async {
    _ensureOpen();
    final result = await _processRunner('wpctl', [operation, ...arguments]);
    if (result.exitCode != 0) {
      final stderrText = result.stderr.toString().trim();
      throw AudioBackendCommandException(
        operation: operation,
        exitCode: result.exitCode,
        stderr: stderrText.isEmpty ? null : stderrText,
      );
    }
    return result;
  }

  static _ParsedVolume _parseVolume(String output) {
    final match = RegExp(
      r'Volume:\s*([0-9]+(?:\.[0-9]+)?)',
      caseSensitive: false,
    ).firstMatch(output);
    if (match == null) {
      throw FormatException('Could not parse wpctl get-volume output: $output');
    }
    final rawVolume = double.parse(match.group(1)!);
    if (!rawVolume.isFinite || rawVolume < 0) {
      throw FormatException('Invalid wpctl volume: $rawVolume');
    }
    return _ParsedVolume(
      rawVolume.clamp(0.0, 1.0),
      output.toUpperCase().contains('[MUTED]'),
    );
  }

  static Set<AudioChannelPosition> _parseChannels(String output) {
    final match = RegExp(r'audio\.position\s*=\s*"?\[([^\]]+)\]')
        .firstMatch(output);
    if (match == null) return const {};
    final channels = <AudioChannelPosition>{};
    for (final token in match.group(1)!.split(RegExp(r'[,\s]+'))) {
      switch (token.trim().toUpperCase()) {
        case 'FL':
          channels.add(AudioChannelPosition.frontLeft);
        case 'FR':
          channels.add(AudioChannelPosition.frontRight);
        case 'RL':
          channels.add(AudioChannelPosition.rearLeft);
        case 'RR':
          channels.add(AudioChannelPosition.rearRight);
      }
    }
    return channels;
  }

  void _replace({double? masterVolume, bool? muted}) {
    _state = AudioBackendState(
      available: _state.available,
      capabilities: _state.capabilities,
      masterVolume: masterVolume ?? _state.masterVolume,
      muted: muted ?? _state.muted,
      selectedOutput: _state.selectedOutput,
      channels: _state.channels,
    );
    _changes.add(_state);
  }

  void _ensureOpen() {
    if (_closed) throw StateError('PipeWire audio backend is closed.');
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _changes.close();
  }

  static Future<ProcessResult> _runProcess(
    String executable,
    List<String> arguments,
  ) => Process.run(executable, arguments);
}

final class AudioBackendCommandException implements Exception {
  const AudioBackendCommandException({
    required this.operation,
    required this.exitCode,
    this.stderr,
  });

  final String operation;
  final int exitCode;
  final String? stderr;

  @override
  String toString() =>
      'wpctl $operation failed with exit code $exitCode'
      '${stderr == null ? '.' : ': $stderr'}';
}

final class _ParsedVolume {
  const _ParsedVolume(this.volume, this.muted);
  final double volume;
  final bool muted;
}
