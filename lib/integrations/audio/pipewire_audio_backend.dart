import 'dart:async';
import 'dart:io';
import 'dart:convert';

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
final class PipeWireAudioBackend implements AudioBackend, AudioOutputSetup {
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
        outputSelection: true,
      ),
      masterVolume: parsed.volume,
      muted: parsed.muted,
      selectedOutput: null,
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
  Future<void> selectOutput(String? outputId) async {
    if (outputId == null) {
      await _run('clear-default', [
        '0',
      ]); // Audio/Sink only; preserve input choice.
    } else {
      final nodes = await _outputNodes();
      final matches = nodes.where((node) => node.$2.id == outputId).toList();
      if (matches.length != 1) {
        throw StateError(
          'The selected output is absent or ambiguous. Reconnect it and refresh outputs.',
        );
      }
      await _run('set-default', [matches.single.$1.toString()]);
    }
    // Read the new output level; never copy the old output volume onto it.
    final level = _parseVolume(
      (await _run('get-volume', [_sink])).stdout.toString(),
    );
    _state = AudioBackendState(
      available: true,
      capabilities: _state.capabilities,
      masterVolume: level.volume,
      muted: level.muted,
      selectedOutput: outputId,
      channels: _parseChannels(
        (await _run('inspect', [_sink])).stdout.toString(),
      ),
    );
    _changes.add(_state);
  }

  Future<List<(int, AudioOutputDevice)>> _outputNodes() async {
    _ensureOpen();
    final result = await _processRunner('pw-dump', []);
    if (result.exitCode != 0) {
      throw StateError('Output discovery failed: ${result.stderr}');
    }
    final nodes = jsonDecode(result.stdout.toString()) as List;
    return [
      for (final node in nodes)
        if (node is Map &&
            node['id'] is int &&
            node['info'] is Map &&
            node['info']['props'] is Map &&
            node['info']['props']['media.class'] == 'Audio/Sink' &&
            node['info']['props']['node.name'] is String)
          (
            node['id'] as int,
            AudioOutputDevice(
              id: node['info']['props']['node.name'] as String,
              name:
                  (node['info']['props']['node.description'] ??
                          node['info']['props']['node.nick'] ??
                          'Audio output')
                      .toString(),
            ),
          ),
    ];
  }

  @override
  Future<List<AudioOutputDevice>> discoverOutputs() async => [
    for (final node in await _outputNodes()) node.$2,
  ];

  bool _testing = false;
  @override
  Future<void> testOutput() async {
    _ensureOpen();
    if (_testing) throw StateError('An output test is already running.');
    _testing = true;
    try {
      // Two seconds at 3% amplitude. PipeWire applies the existing output
      // volume and mute. No master control or persisted PCM is involved.
      final result = await _processRunner('gst-launch-1.0', [
        '-q',
        'audiotestsrc',
        'wave=sine',
        'freq=440',
        'volume=0.03',
        'samplesperbuffer=480',
        'num-buffers=200',
        '!',
        'audio/x-raw,rate=48000,channels=2',
        '!',
        'audioconvert',
        '!',
        'pipewiresink',
        'sync=true',
      ]);
      if (result.exitCode != 0) {
        throw StateError('Output test failed: ${result.stderr}');
      }
    } finally {
      _testing = false;
    }
  }

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
  ) async {
    final process = await Process.start(executable, arguments);
    final output = <int>[], errors = <int>[];
    Object? failure;
    void collect(List<int> target, List<int> bytes) {
      if (target.length + bytes.length > 1024 * 1024) {
        failure ??= StateError('$executable output exceeded 1 MiB');
        process.kill(ProcessSignal.sigkill);
      } else {
        target.addAll(bytes);
      }
    }

    final stdoutDone = process.stdout
        .listen((b) => collect(output, b))
        .asFuture<void>();
    final stderrDone = process.stderr
        .listen((b) => collect(errors, b))
        .asFuture<void>();
    final timer = Timer(const Duration(seconds: 6), () {
      failure ??= TimeoutException(
        '$executable did not finish within six seconds',
      );
      process.kill(ProcessSignal.sigkill);
    });
    try {
      final code = await process.exitCode;
      await Future.wait([stdoutDone, stderrDone]);
      if (failure != null) throw failure!;
      return ProcessResult(
        process.pid,
        code,
        utf8.decode(output, allowMalformed: true),
        utf8.decode(errors, allowMalformed: true),
      );
    } finally {
      timer.cancel();
    }
  }
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
