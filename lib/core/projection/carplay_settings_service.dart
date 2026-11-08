import '../diagnostics/service_failure.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Persistent native receiver settings; no media or phone credentials enter Dart.
class CarPlaySettingsService {
  CarPlaySettingsService({required this.socketPath, this.selectedMicrophone});
  final String socketPath;
  final String? Function()? selectedMicrophone;
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
  Timer? _viewportTimer;
  (double, double, double)? _viewport;
  (double, double, double)? _sentViewport;
  (double, double, double)? get measuredViewport => _viewport;
  final Set<Socket> _sockets = {};
  String? _sentSource;

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
      final source = selectedMicrophone?.call();
      if (source != null &&
          source.isNotEmpty &&
          source != _sentSource &&
          (reply['settings'] as Map)['audio_sink'] != null) {
        await _request({
          'action': 'configure',
          'settings': {'audio_source': source},
        });
        _sentSource = source;
      }
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
      _sentSource = null;
      _sentViewport = null;
    }
    _notify();
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
      if (command['action'] == 'connect') await _syncViewport();
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
    await _changes.close();
  }
}
