import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/projection/carplay_link_diagnostics.dart';

/// Cached daemon health only. Never opens dongle radios, starts a session,
/// launches a process, or sends MFi certificate/challenge bytes through Dart.
final class CarPlayLinkDiagnosticsClient implements CarPlayLinkDiagnostics {
  CarPlayLinkDiagnosticsClient({
    required this.socketPath,
    this.pollInterval = const Duration(seconds: 5),
    this.requestTimeout = const Duration(seconds: 2),
  }) {
    if (!socketPath.startsWith('/') ||
        socketPath.contains('\u0000') ||
        socketPath.endsWith('/') ||
        utf8.encode(socketPath).length >= 108) {
      throw ArgumentError(
        'CarPlay health socket must be an absolute Unix path.',
      );
    }
    if (pollInterval <= Duration.zero || requestTimeout <= Duration.zero) {
      throw ArgumentError(
        'CarPlay health polling requires positive deadlines.',
      );
    }
  }

  final String socketPath;
  final Duration pollInterval, requestTimeout;
  final _changes = StreamController<CarPlayLinkHealth>.broadcast(sync: true);
  CarPlayLinkHealth _current = const CarPlayLinkHealth();
  Timer? _timer;
  Socket? _socket;
  Future<void>? _inFlight;
  Future<void>? _closing;
  bool _closed = false;
  bool _started = false;

  @override
  CarPlayLinkHealth get current => _current;
  @override
  Stream<CarPlayLinkHealth> get changes => _changes.stream;

  void start() {
    if (_closed) throw StateError('CarPlay diagnostics are closed.');
    if (_started) return;
    _started = true;
    unawaited(refresh());
  }

  @override
  Future<void> refresh() {
    if (_closed) return Future.value();
    _timer?.cancel();
    return _inFlight ??= _poll().whenComplete(() {
      _inFlight = null;
      if (!_closed && _started) _timer = Timer(pollInterval, refresh);
    });
  }

  Future<void> _poll() async {
    final elapsed = Stopwatch()..start();
    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
        timeout: requestTimeout,
      );
      if (_closed) return;
      _socket = socket;
      final remaining = requestTimeout - elapsed.elapsed;
      if (remaining <= Duration.zero) throw TimeoutException('Health deadline');
      socket.write('status\n');
      final payload = await _readLine(socket).timeout(remaining);
      _publish(decodeCarPlayLinkHealth(payload));
    } on TimeoutException {
      _publish(
        const CarPlayLinkHealth(error: 'LIVI Link diagnostics timed out.'),
      );
    } on Object {
      _publish(
        const CarPlayLinkHealth(error: 'LIVI Link diagnostics unavailable.'),
      );
    } finally {
      socket?.destroy();
      if (identical(_socket, socket)) _socket = null;
    }
  }

  static Future<String> _readLine(Socket socket) async {
    final bytes = <int>[];
    await for (final chunk in socket) {
      // Bound the whole received chunk too; reject extra messages/trailing data.
      if (bytes.length + chunk.length > 4096) {
        throw const FormatException(
          'CarPlay health response exceeds 4096 bytes.',
        );
      }
      final newline = chunk.indexOf(10);
      if (newline >= 0) {
        if (newline != chunk.length - 1) {
          throw const FormatException('Unexpected data after CarPlay health.');
        }
        bytes.addAll(chunk.take(newline));
        return utf8.decode(bytes);
      }
      bytes.addAll(chunk);
    }
    throw const FormatException('Truncated CarPlay health response.');
  }

  void _publish(CarPlayLinkHealth health) {
    if (_closed || health == _current) return;
    _current = health;
    _changes.add(health);
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    _timer?.cancel();
    _socket?.destroy();
    await _inFlight;
    await _changes.close();
  }
}

/// Contract 1 is deliberately diagnostics-only. A future session implementation
/// needs its own reviewed control contract rather than claiming support here.
CarPlayLinkHealth decodeCarPlayLinkHealth(String payload) {
  if (utf8.encode(payload).length > 4095) {
    throw const FormatException('Oversized CarPlay health response.');
  }
  final value = jsonDecode(payload);
  if (value is! Map<String, dynamic> ||
      value['contract'] != 1 ||
      value['implementation'] != 'diagnostics-only' ||
      value['session_validated'] != false ||
      value['bluetooth_bridge'] != 'not-probed' ||
      value['iap_handoff'] != 'not-probed') {
    throw const FormatException('Unsupported CarPlay health contract.');
  }
  final resolved = switch (value['discovery']) {
    'resolved' => true,
    'unavailable' => false,
    _ => throw const FormatException('Invalid Link discovery state.'),
  };
  final mfi = switch (value['mfi']) {
    'unavailable' => CarPlayMfiHealth.unavailable,
    'certificate-only' => CarPlayMfiHealth.certificateOnly,
    'ready' => CarPlayMfiHealth.ready,
    _ => throw const FormatException('Invalid MFi state.'),
  };
  final wifi = switch (value['wifi']) {
    'ready' => true,
    'unavailable' => false,
    _ => throw const FormatException('Invalid Wi-Fi state.'),
  };
  final address = value['address'];
  if (address != null &&
      (address is! String ||
          InternetAddress.tryParse(address)?.type !=
              InternetAddressType.IPv4)) {
    throw const FormatException('Invalid Link IPv4 address.');
  }
  final major = value['protocol_major'];
  if (major != null && (major is! int || major < 0 || major > 255)) {
    throw const FormatException('Invalid MFi protocol generation.');
  }
  final certificateBytes = value['certificate_bytes'];
  if (certificateBytes != null &&
      (certificateBytes is! int ||
          certificateBytes <= 0 ||
          certificateBytes > 4096)) {
    throw const FormatException('Invalid MFi certificate size.');
  }
  if (resolved != (address != null) ||
      (mfi != CarPlayMfiHealth.unavailable &&
          (!resolved || certificateBytes == null)) ||
      (mfi == CarPlayMfiHealth.ready && major == null)) {
    throw const FormatException('Inconsistent Link readiness.');
  }
  final status = value['wifi_status'];
  if ((wifi &&
          (status is! Map<String, dynamic> ||
              status['access_point_enabled'] is! bool ||
              status['bluetooth_enabled'] is! bool)) ||
      (!wifi && status != null)) {
    throw const FormatException('Invalid Link radio status.');
  }
  final error = value['error'];
  if (error != null && (error is! String || error.length > 1024)) {
    throw const FormatException('Invalid Link diagnostic message.');
  }
  return CarPlayLinkHealth(
    serviceAvailable: true,
    linkResolved: resolved,
    address: address as String?,
    mfi: mfi,
    protocolMajor: major as int?,
    wifiControlAvailable: wifi,
    accessPointEnabled: wifi ? status['access_point_enabled'] as bool : null,
    bluetoothEnabled: wifi ? status['bluetooth_enabled'] as bool : null,
    error: error as String?,
  );
}
