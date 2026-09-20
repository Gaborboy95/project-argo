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
  Timer? _timer;
  bool _closed = false;
  Future<void>? _polling;
  final Set<Socket> _sockets = {};
  String? _sentSource;

  Future<Map<String, dynamic>> _request(Map<String, Object?> request) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      ).timeout(const Duration(seconds: 2));
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
  Future<void> refresh() => _polling ??= _refresh().whenComplete(() {
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
    } on Object {
      available = false;
      error = 'CarPlay service unavailable.';
      _sentSource = null;
    }
    _notify();
  }

  Future<void> configure(Map<String, Object?> settings) =>
      _change({'action': 'configure', 'settings': settings});
  Future<void> connect() => _change({'action': 'connect'});
  Future<void> disconnect() => _change({'action': 'disconnect'});
  Future<void> _change(Map<String, Object?> command) async {
    if (saving || _closed) return;
    saving = true;
    _notify();
    try {
      await _request(command);
      await refresh();
    } on Object catch (e) {
      error = '$e';
    } finally {
      saving = false;
      _notify();
    }
  }

  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
    await _polling;
    await _changes.close();
  }
}
