import '../diagnostics/service_failure.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Persistent native receiver settings; no media or phone credentials enter Dart.
class CarPlaySettingsService {
  CarPlaySettingsService({
    required this.socketPath,
    this.selectedMicrophone,
    this.selectedAudioOutput,
  });
  final String socketPath;
  final String? Function()? selectedMicrophone;
  final String? Function()? selectedAudioOutput;
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  Map<String, dynamic> current = const {};
  bool available = false;
  bool saving = false;
  String? error;
  ServiceFailure? failure;
  Timer? _timer;
  bool _closed = false;
  Future<void>? _polling;
  Future<void>? _sendingViewport;
  Future<void>? _sendingAudio;
  Timer? _viewportTimer;
  (double, double, double)? _viewport;
  (double, double, double)? _sentViewport;
  (double, double, double)? get measuredViewport => _viewport;
  final Set<Socket> _sockets = {};

  Future<Map<String, dynamic>> _request(Map<String, Object?> request) async {
    if (_closed) throw StateError('CarPlay settings are closed');
    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
        timeout: const Duration(seconds: 2),
      );
      if (_closed) throw StateError('CarPlay settings are closed');
      _sockets.add(socket);
      socket.write('${jsonEncode(request)}\n');
      final bytes = <int>[];
      final reply = await (() async {
        await for (final chunk in socket!) {
          for (final b in chunk) {
            if (b == 10) {
              return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
            }
            if (bytes.length >= 16384) {
              throw const FormatException('CarPlay response too large');
            }
            bytes.add(b);
          }
        }
        throw const FormatException('Incomplete CarPlay response');
      })().timeout(const Duration(seconds: 2));
      if (reply['ok'] != true) {
        throw StateError(
          reply['error'] as String? ?? 'CarPlay operation failed',
        );
      }
      return reply;
    } finally {
      _sockets.remove(socket);
      socket?.destroy();
    }
  }

  void _notify() {
    if (!_closed) _changes.add(null);
  }

  Future<void> start() => refresh();
  Future<void> refresh() => _closed
      ? Future<void>.value()
      : _polling ??= _refresh().whenComplete(() {
          _polling = null;
          _timer?.cancel();
          if (!_closed) _timer = Timer(const Duration(seconds: 1), refresh);
        });
  Future<void> _refresh() async {
    try {
      final reply = await _request({'action': 'status'});
      if (reply['contract'] != 1 || reply['settings'] is! Map) {
        throw const FormatException('Unsupported CarPlay settings');
      }
      current = reply;
      available = true;
      error = null;
      failure = null;
      final reported = reply['viewport'];
      final sent = _sentViewport;
      if (sent != null &&
          (reported is! Map ||
              reported['width'] != sent.$1 ||
              reported['height'] != sent.$2 ||
              reported['overlay_height'] != sent.$3)) {
        _sentViewport = null;
      }
      await _syncViewport();
      await _syncSharedAudio();
    } on Object catch (cause) {
      available = false;
      failure = ServiceFailure(
        feature: 'carplay',
        operation: 'status',
        kind: cause is SocketException
            ? FailureKind.missingService
            : FailureKind.rejected,
        summary: 'Could not read CarPlay receiver settings',
        cause: cause,
        retryable: true,
        recovery: 'Check the receiver service and retry.',
      );
      error = failure!.summary;
      _sentViewport = null;
    }
    _notify();
  }

  Map<String, String> _sharedAudioPatch() {
    final settings = current['settings'] as Map? ?? const {};
    final sink = selectedAudioOutput?.call();
    final source = selectedMicrophone?.call();
    final selectedSink = sink != null && sink.isNotEmpty ? sink : null;
    final effectiveSink = selectedSink ?? settings['audio_sink'];
    return {
      if (selectedSink != null && selectedSink != settings['audio_sink'])
        'audio_sink': selectedSink,
      if (source != null &&
          source.isNotEmpty &&
          effectiveSink is String &&
          effectiveSink.isNotEmpty &&
          source != settings['audio_source'])
        'audio_source': source,
    };
  }

  /// Shared choices configure the next phone negotiation. Updating these
  /// preferences never starts, stops or reconnects an existing receiver.
  Future<void> _syncSharedAudio() {
    if (_closed || !available) return Future<void>.value();
    final pending = _sendingAudio;
    if (pending != null) return pending;
    final patch = _sharedAudioPatch();
    if (patch.isEmpty) return Future<void>.value();
    final operation = _request({'action': 'configure', 'settings': patch});
    _sendingAudio = operation
        .then((_) {
          if (_closed) return;
          // The native acknowledgement confirms saved preferences, not a live
          // route change. Keep the cache coherent until the next status poll.
          current = {
            ...current,
            'settings': {...current['settings'] as Map, ...patch},
          };
        })
        .whenComplete(() => _sendingAudio = null);
    return _sendingAudio!;
  }

  /// Runtime dashboard measurements; applied at the next phone negotiation.
  /// Resizing never writes persistent preferences or disconnects a session.
  void setViewport(double width, double height, double overlayHeight) {
    if (_closed ||
        !width.isFinite ||
        !height.isFinite ||
        !overlayHeight.isFinite ||
        width < 1 ||
        height < 1 ||
        width > 65536 ||
        height > 65536 ||
        overlayHeight < 0 ||
        overlayHeight >= height) {
      return;
    }
    final next = (width, height, overlayHeight);
    if (_viewport == next) return;
    _viewport = next;
    _viewportTimer?.cancel();
    _viewportTimer = Timer(const Duration(milliseconds: 150), () async {
      try {
        await _syncViewport();
      } on Object {
        // The next status poll retries using the latest measurement.
        _sentViewport = null;
      }
    });
  }

  Future<void> _syncViewport() async {
    final value = _viewport;
    if (_closed ||
        !available ||
        current['viewport_supported'] != true ||
        value == null ||
        value == _sentViewport) {
      return;
    }
    if (_sendingViewport != null) return _sendingViewport;
    final operation = _request({
      'action': 'viewport',
      'viewport': {
        'width': value.$1,
        'height': value.$2,
        'overlay_height': value.$3,
      },
    });
    _sendingViewport = operation.then((_) {
      if (!_closed) _sentViewport = value;
    });
    try {
      await _sendingViewport;
    } finally {
      _sendingViewport = null;
    }
  }

  Future<void> configure(Map<String, Object?> settings) =>
      _change({'action': 'configure', 'settings': settings});
  Future<void> connect() => _change({'action': 'connect'});
  Future<void> connectDevice(String address) =>
      _change({'action': 'connect', 'target': address});
  Future<void> disconnect() => _change({'action': 'disconnect'});
  Future<void> _change(Map<String, Object?> command) async {
    if (saving || _closed) return;
    saving = true;
    _notify();
    try {
      if (command['action'] == 'connect') {
        await refresh();
        if (!available || failure != null) {
          throw StateError(error ?? 'CarPlay receiver settings unavailable');
        }
        await _syncViewport();
        await _syncSharedAudio();
        // A selection changed while an earlier configure request was in
        // flight. Apply its latest value once, without an unbounded retry loop.
        if (_sharedAudioPatch().isNotEmpty) await _syncSharedAudio();
        if (_sharedAudioPatch().isNotEmpty) {
          throw StateError('Shared audio selection changed; retry Connect');
        }
      }
      await _request(command);
      await refresh();
    } on Object catch (e) {
      failure = ServiceFailure(
        feature: 'carplay',
        operation: 'configure',
        kind: FailureKind.rejected,
        summary: 'Could not update CarPlay',
        cause: e,
        retryable: true,
      );
      error = failure!.summary;
    } finally {
      saving = false;
      _notify();
    }
  }

  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    _viewportTimer?.cancel();
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
    await _polling;
    try {
      await _sendingViewport;
    } on Object {
      // Closing owned sockets cancels an outstanding viewport request.
    }
    try {
      await _sendingAudio;
    } on Object {
      // Closing owned sockets cancels an outstanding shared-audio update.
    }
    await _changes.close();
  }
}
