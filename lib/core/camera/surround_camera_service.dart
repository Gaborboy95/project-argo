import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import '../settings/app_setting_keys.dart';
import '../settings/settings_service.dart';
import 'camera_service.dart';

/// Reconnecting metadata client. Closing Argo never stops the external engine.
final class SurroundCameraService
    implements CameraService, SurroundCameraControl {
  SurroundCameraService({
    required this._settings,
    required this._environment,
    this.registerNative = true,
  });
  final SettingsService _settings;
  final Map<String, String> _environment;
  final bool registerNative;
  final _events = StreamController<CameraSnapshot>.broadcast(sync: true);
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  CameraSnapshot _current = const CameraSnapshot(external: true);
  Socket? _socket;
  Timer? _retry, _poll;
  Future<void>? _connecting;
  Future<void> _tail = Future.value();
  CameraRole? _desired;
  String? _lease;
  int _id = 0, _epoch = 0;
  bool _closed = false, _polling = false;
  DynamicLibrary? _library;
  void Function(int)? _nativeRole;
  @override
  CameraSnapshot get current => _current;
  @override
  Stream<CameraSnapshot> get changes => _events.stream;
  String get _directory =>
      _environment['SURROUND_CAMERA_RUNTIME'] ??
      '${_environment['XDG_RUNTIME_DIR'] ?? '/run/user/invalid'}/surround-camera';

  Future<void> initialize() =>
      _connecting ??= _connect().whenComplete(() => _connecting = null);
  Future<void> _connect() async {
    if (_closed || _socket != null) return;
    try {
      if (!_directory.startsWith('/') ||
          _directory.contains('\x00') ||
          utf8.encode('$_directory/control.sock').length >= 108) {
        throw const FormatException('Invalid surround-camera runtime path');
      }
      if (registerNative && _library == null) {
        final bundle = _environment['ARGO_WIRELESS_BUNDLE'];
        final path =
            _environment['ARGO_CAMERA_VIEW_LIBRARY'] ??
            (bundle == null
                ? 'libargo_camera_view.so'
                : '$bundle/lib/libargo_camera_view.so');
        _library = DynamicLibrary.open(path);
        final result = _library!
            .lookupFunction<Int32 Function(), int Function()>(
              'argo_surround_camera_view_register',
            )();
        if (result != 0) {
          throw StateError(
            'External camera factory registration failed ($result)',
          );
        }
        _nativeRole = _library!
            .lookupFunction<Void Function(Uint32), void Function(int)>(
              'argo_surround_camera_view_set_role',
            );
      }
      final socket = await Socket.connect(
        InternetAddress(
          '$_directory/control.sock',
          type: InternetAddressType.unix,
        ),
        0,
        timeout: const Duration(milliseconds: 500),
      );
      if (_closed) {
        socket.destroy();
        return;
      }
      _socket = socket;
      final decoder = SurroundControlDecoder();
      socket.listen(
        (bytes) {
          try {
            for (final message in decoder.add(bytes)) {
              if (message['major'] != 1) {
                throw const FormatException('Incompatible surround-camera API');
              }
              final waiter = _pending.remove(message['id']);
              if (waiter == null) continue;
              if (message['ok'] == true) {
                waiter.complete(
                  Map<String, dynamic>.from(message['result'] as Map? ?? {}),
                );
              } else {
                waiter.completeError(StateError('${message['error']}'));
              }
            }
          } on Object catch (error) {
            _disconnected(socket, error);
          }
        },
        onError: (Object error) => _disconnected(socket, error),
        onDone: () => _disconnected(socket, 'Surround-camera disconnected'),
      );
      await command('hello', {'min_minor': 0});
      await _refresh();
      // Import only if the engine has no assignment. Clear the old preference
      // only after the engine has durably acknowledged the import.
      final rear = _settings.get(AppSettingKeys.cameraRear);
      if (rear.isNotEmpty) {
        await command('assign', {
          'role': 'rear',
          'camera_id': rear,
          'if_unassigned': true,
        }, true);
        await _settings.set(AppSettingKeys.cameraRear, '');
        await _refresh();
      }
      _retry?.cancel();
      _poll = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (_polling || _socket == null) return;
        _polling = true;
        unawaited(
          _refresh()
              .catchError((Object error) {
                if (_socket != null) _disconnected(_socket!, error);
              })
              .whenComplete(() => _polling = false),
        );
      });
      if (_desired != null) await _subscribe(_desired!);
    } on Object catch (error) {
      if (_socket != null) {
        _disconnected(_socket!, error);
      } else {
        _unavailable(error);
        _scheduleRetry();
      }
    }
  }

  void _scheduleRetry() {
    if (_closed) return;
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 2), () => unawaited(initialize()));
  }

  void _unavailable(Object error) {
    if (_closed) return;
    _current = CameraSnapshot(
      external: true,
      assignments: _current.assignments,
      groups: _current.groups,
      activeRole: _desired,
      state: CameraStreamState.disconnected,
      error: '$error'
          .replaceAll('\n', ' ')
          .substring(0, '$error'.length.clamp(0, 300)),
    );
    _events.add(_current);
  }

  void _disconnected(Socket socket, Object error) {
    if (!identical(socket, _socket)) return;
    _socket = null;
    socket.destroy();
    _lease = null;
    _epoch++;
    _poll?.cancel();
    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(StateError('Surround-camera disconnected'));
      }
    }
    _pending.clear();
    _unavailable(error);
    _scheduleRetry();
  }

  @override
  Future<Map<String, dynamic>> command(
    String operation, [
    Map<String, Object?> arguments = const {},
    bool administration = false,
  ]) async {
    if (administration) return _admin(operation, arguments);
    final socket = _socket;
    if (socket == null || _closed) {
      throw StateError('Surround-camera unavailable');
    }
    if (_pending.length >= 32) throw StateError('Too many camera commands');
    final id = ++_id;
    final waiter = Completer<Map<String, dynamic>>();
    _pending[id] = waiter;
    socket.add(SurroundControlDecoder.encode(id, operation, arguments));
    try {
      return await waiter.future.timeout(const Duration(seconds: 5));
    } finally {
      _pending.remove(id);
    }
  }

  Future<Map<String, dynamic>> _admin(
    String operation,
    Map<String, Object?> arguments,
  ) async {
    final socket = await Socket.connect(
      InternetAddress('$_directory/admin.sock', type: InternetAddressType.unix),
      0,
      timeout: const Duration(seconds: 1),
    );
    final done = Completer<Map<String, dynamic>>();
    final id = ++_id;
    final decoder = SurroundControlDecoder();
    socket.listen(
      (bytes) {
        try {
          for (final message in decoder.add(bytes)) {
            if (done.isCompleted || message['id'] != id) continue;
            if (message['major'] != 1 || message['ok'] != true) {
              done.completeError(
                StateError(
                  '${message['error'] ?? 'Incompatible administration API'}',
                ),
              );
            } else {
              done.complete(
                Map<String, dynamic>.from(message['result'] as Map? ?? {}),
              );
            }
          }
        } on Object catch (error) {
          if (!done.isCompleted) done.completeError(error);
        }
      },
      onError: (Object error) {
        if (!done.isCompleted) done.completeError(error);
      },
      onDone: () {
        if (!done.isCompleted) {
          done.completeError(StateError('Administration disconnected'));
        }
      },
    );
    try {
      socket.add(SurroundControlDecoder.encode(id, operation, arguments));
      return await done.future.timeout(const Duration(seconds: 10));
    } finally {
      socket.destroy();
    }
  }

  Future<void> _refresh() async {
    final status = await command('status');
    final devices = (status['devices'] as List? ?? [])
        .map(
          (dynamic d) => CameraDevice(
            stableId: d['stableId'] as String,
            displayName: d['displayName'] as String,
            currentVideoNode: d['node'] as String? ?? '',
          ),
        )
        .toList();
    final assigned = <CameraRole, String>{};
    (status['assignments'] as Map? ?? {}).forEach((key, value) {
      final role = CameraRole.values.where((r) => r.name == key).firstOrNull;
      if (role != null && value is String) assigned[role] = value;
    });
    final streams = status['streams'] as List? ?? [];
    final stream =
        streams
                .where((dynamic s) => s['camera_id'] == assigned[_desired])
                .firstOrNull
            as Map?;
    final frame = stream ?? const {};
    final state = CameraStreamState.values
        .where((s) => s.name == frame['state'])
        .firstOrNull;
    _current = CameraSnapshot(
      available: true,
      external: true,
      devices: devices,
      assignments: assigned,
      activeRole: _desired,
      groups: (status['groups'] as Map? ?? {}).map(
        (key, value) => MapEntry('$key', List<String>.from(value as List)),
      ),
      state: _desired == null
          ? CameraStreamState.idle
          : state ?? CameraStreamState.starting,
      width: frame['width'] as int?,
      height: frame['height'] as int?,
      stride: frame['stride'] as int?,
      sequence: frame['sequence'] as int? ?? 0,
      error: frame['error'] as String?,
      details: status,
    );
    if (!_closed) _events.add(_current);
  }

  Future<void> _serialize(Future<void> Function() work) {
    final future = _tail.then((_) async {
      if (!_closed) await work();
    });
    _tail = future.catchError((Object error) {
      _unavailable(error);
    });
    return _tail;
  }

  @override
  Future<void> assign(CameraRole role, String stableId) => _serialize(() async {
    await command('assign', {'role': role.name, 'camera_id': stableId}, true);
    await _refresh();
  });
  Future<void> _subscribe(CameraRole role) async {
    _nativeRole?.call(role.index);
    if (_lease != null) {
      await command('unsubscribe', {'subscription_id': _lease});
    }
    final epoch = _epoch;
    final result = await command('subscribe', {
      'role': role.name,
      'formats': ['BGRx'],
      'consumer': 'display',
      'delivery': 'latest',
      'max_outstanding': 1,
    });
    if (epoch == _epoch) _lease = '${result['subscription_id']}';
    await _refresh();
  }

  @override
  Future<void> start(CameraRole role) {
    _desired = role;
    return _serialize(() async {
      await initialize();
      if (_socket != null && _desired == role && _lease == null) {
        await _subscribe(role);
      } else if (_socket != null && _desired == role)
        await _subscribe(role);
    });
  }

  @override
  Future<void> stop() {
    _desired = null;
    return _serialize(() async {
      final lease = _lease;
      _lease = null;
      if (_socket != null && lease != null) {
        await command('unsubscribe', {'subscription_id': lease});
      }
      if (_socket != null) await _refresh();
    });
  }

  @override
  Future<void> refresh() => _serialize(() async {
    await initialize();
    if (_socket != null) {
      await command('discover');
      await _refresh();
    }
  });
  @override
  Future<void> selectView(String mode, {String? group}) async {
    await command('view', {'mode': mode, 'group': group});
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    await stop();
    _closed = true;
    _retry?.cancel();
    _poll?.cancel();
    _socket?.destroy();
    _socket = null;
    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(StateError('Client closed'));
      }
    }
    _pending.clear();
    await _events.close();
  }
}

/// Versioned, bounded metadata framing; byte-at-a-time input cannot grow past 64 KiB.
final class SurroundControlDecoder {
  final List<int> _bytes = [];
  Iterable<Map<String, dynamic>> add(List<int> input) sync* {
    for (final byte in input) {
      _bytes.add(byte);
      if (_bytes.length < 4) continue;
      final length =
          (_bytes[0] << 24) | (_bytes[1] << 16) | (_bytes[2] << 8) | _bytes[3];
      if (length == 0 || length > 65536) {
        throw const FormatException('Invalid surround-camera message length');
      }
      if (_bytes.length == length + 4) {
        final value = jsonDecode(utf8.decode(_bytes.sublist(4)));
        _bytes.clear();
        if (value is! Map<String, dynamic>) {
          throw const FormatException('Expected protocol object');
        }
        yield value;
      }
    }
  }

  static Uint8List encode(
    int id,
    String operation,
    Map<String, Object?> arguments,
  ) {
    final body = utf8.encode(
      jsonEncode({
        'major': 1,
        'minor': 0,
        'id': id,
        'op': operation,
        'args': arguments,
      }),
    );
    if (body.length > 65536) {
      throw const FormatException('Camera command exceeds limit');
    }
    return Uint8List.fromList([
      ...(ByteData(4)..setUint32(0, body.length)).buffer.asUint8List(),
      ...body,
    ]);
  }
}
