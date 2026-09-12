import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../settings/app_setting_keys.dart';
import '../settings/settings_service.dart';
import 'camera_service.dart';

/// Application-owned camera process. IPC contains only commands and metadata.
final class NativeCameraService implements CameraService {
  NativeCameraService({
    required SettingsService settings,
    required this._environment,
  }) : _settings = settings {
    final saved = settings.get(AppSettingKeys.cameraRear);
    if (saved.isNotEmpty) _assignments[CameraRole.rear] = saved;
    _publish();
  }
  final SettingsService _settings;
  final Map<String, String> _environment;
  final _events = StreamController<CameraSnapshot>.broadcast(sync: true);
  final _assignments = <CameraRole, String>{};
  final _commands = <int, Completer<void>>{};
  CameraSnapshot _current = const CameraSnapshot();
  Process? _process;
  Socket? _socket;
  Directory? _directory;
  DynamicLibrary? _library;
  Future<void>? _initializing;
  Future<void> _tail = Future.value();
  CameraRole? _desired;
  List<CameraDevice> _devices = [];
  CameraStreamState _state = CameraStreamState.idle;
  String? _error;
  bool _available = false, _closed = false;
  int _id = 0, _sequence = 0, _requestEpoch = 0;
  Map<String, dynamic> _frame = {};
  DateTime? _lastFrame;
  @override
  CameraSnapshot get current => _current;
  @override
  Stream<CameraSnapshot> get changes => _events.stream;
  void _publish() {
    _current = CameraSnapshot(
      available: _available,
      devices: List.unmodifiable(_devices),
      assignments: Map.unmodifiable(_assignments),
      activeRole: _desired,
      state: _state,
      width: (_frame['width'] as int?) == 0 ? null : _frame['width'] as int?,
      height: (_frame['height'] as int?) == 0 ? null : _frame['height'] as int?,
      stride: _frame['stride'] as int?,
      fps: (_frame['fps'] as num?)?.toDouble(),
      sequence: _sequence,
      lastFrame: _lastFrame,
      error: _error,
    );
    if (!_events.isClosed) _events.add(_current);
  }

  void _fail(Object error) {
    if (_closed) return;
    _error = '$error'.replaceAll('\n', ' ');
    if (_error!.length > 240) _error = _error!.substring(0, 240);
    _state = CameraStreamState.failed;
    _frame = {};
    _lastFrame = null;
    _publish();
    debugPrint('Argo camera: $_error');
  }

  Future<void> initialize() => _initializing ??= _initialize();
  Future<void> _initialize() async {
    try {
      final bundle = _environment['ARGO_WIRELESS_BUNDLE'];
      if (bundle == null) {
        throw StateError('Selected release has no camera assets');
      }
      final manifest = jsonDecode(
        await File('$bundle/argo-release.json').readAsString(),
      ) as Map;
      if (manifest['camera_contract'] != 1 ||
          !await File('$bundle/bin/argo-camerad').exists() ||
          !await File('$bundle/lib/libargo_camera_view.so').exists()) {
        throw StateError('Selected release has no matched camera pair');
      }
      _library = DynamicLibrary.open('$bundle/lib/libargo_camera_view.so');
      if (_library!.lookupFunction<Int32 Function(), int Function()>(
            'argo_camera_view_register',
          )() !=
          0) {
        throw StateError('Camera native factory registration failed');
      }
      final runtime = _environment['XDG_RUNTIME_DIR'];
      if (runtime == null) {
        throw StateError('XDG_RUNTIME_DIR is required for camera');
      }
      final parent = Directory('$runtime/project-argo');
      await parent.create(recursive: true);
      final dir = Directory('${parent.path}/camera-$pid');
      if (await dir.exists()) {
        throw StateError(
          'Camera runtime directory already exists; previous cleanup uncertain',
        );
      }
      await dir.create();
      // chmod is a direct libc call, never a shell command.
      final chmod = DynamicLibrary.process()
          .lookupFunction<
            Int32 Function(Pointer<Uint8>, Uint32),
            int Function(Pointer<Uint8>, int)
          >('chmod');
      final bytes = utf8.encode('${dir.path}\x00');
      final malloc = DynamicLibrary.process()
          .lookupFunction<
            Pointer<Void> Function(IntPtr),
            Pointer<Void> Function(int)
          >('malloc');
      final free = DynamicLibrary.process()
          .lookupFunction<
            Void Function(Pointer<Void>),
            void Function(Pointer<Void>)
          >('free');
      final ptr = malloc(bytes.length).cast<Uint8>();
      if (ptr == nullptr) {
        throw StateError('Camera directory allocation failed');
      }
      try {
        ptr.asTypedList(bytes.length).setAll(0, bytes);
        if (chmod(ptr, 0x1c0) != 0) {
          throw StateError('Cannot protect camera runtime directory');
        }
      } finally {
        free(ptr.cast());
      }
      _directory = dir;
      if (_closed) return;
      final process = await Process.start(
        '$bundle/bin/argo-camerad',
        [dir.path],
        environment: _environment,
        includeParentEnvironment: false,
      );
      _process = process;
      unawaited(process.stdout.drain<void>());
      process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            debugPrint(
              'argo-camerad: ${line.length > 300 ? line.substring(0, 300) : line}',
            );
          });
      unawaited(
        process.exitCode.then((code) {
          if (!_closed && identical(_process, process)) {
            _available = false;
            _fail('Camera daemon exited ($code)');
          }
          _socket?.destroy();
        }),
      );
      final clock = Stopwatch()..start();
      while (!_closed && clock.elapsed < const Duration(seconds: 5)) {
        try {
          _socket = await Socket.connect(
            InternetAddress(
              '${dir.path}/control.sock',
              type: InternetAddressType.unix,
            ),
            0,
            timeout: const Duration(milliseconds: 200),
          );
          break;
        } on SocketException {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      if (_socket == null) {
        throw StateError('Camera control readiness timed out');
      }
      final decoder = CameraControlDecoder();
      _socket!.listen(
        (bytes) {
          try {
            for (final value in decoder.add(bytes)) {
              _receive(value);
            }
          } on Object catch (e) {
            _fail(e);
            _socket?.destroy();
          }
        },
        onError: (Object e) {
          _fail(e);
        },
        onDone: () {
          for (final c in _commands.values) {
            if (!c.isCompleted) {
              c.completeError(StateError('Camera control disconnected'));
            }
          }
          _commands.clear();
          if (!_closed) {
            _available = false;
            _fail('Camera control disconnected');
          }
        },
      );
      _available = true;
      _error = null;
      _publish();
      await _command('refresh');
    } on Object catch (e) {
      _available = false;
      _fail(e);
      await _terminate();
    }
  }

  void _receive(Map<String, dynamic> value) {
    if (value['version'] != 1) {
      throw const FormatException('Camera IPC version mismatch');
    }
    if (value.containsKey('id')) {
      final c = _commands.remove(value['id']);
      if (c != null) {
        if (value['error'] == null) {
          c.complete();
        } else {
          c.completeError(StateError('${value['error']}'));
        }
      }
      return;
    }
    _devices = (value['devices'] as List)
        .map(
          (dynamic d) => CameraDevice(
            stableId: d['stableId'] as String,
            displayName: d['displayName'] as String,
            currentVideoNode: d['node'] as String,
          ),
        )
        .toList();
    if (_desired != null) {
      _state = CameraStreamState.values.byName(value['state'] as String);
      _frame = Map<String, dynamic>.from(value['frame'] as Map);
      final seq = value['sequence'] as int? ?? 0;
      if (seq > _sequence) _sequence = seq;
      final age = value['lastFrameAgeMs'] as int?;
      _lastFrame = age == null
          ? null
          : DateTime.now().subtract(Duration(milliseconds: age));
      _error = value['error'] as String?;
    }
    if (_desired == null) {
      final rear = _assignments[CameraRole.rear];
      _state = rear != null && !_devices.any((d) => d.stableId == rear)
          ? CameraStreamState.disconnected
          : CameraStreamState.idle;
    }
    _publish();
  }

  Future<void> _command(String op, {CameraRole? role, String? stableId}) async {
    final socket = _socket;
    if (socket == null) throw StateError('Camera daemon unavailable');
    final id = ++_id;
    final done = Completer<void>();
    _commands[id] = done;
    final bytes = utf8.encode(
      jsonEncode({
        'version': 1,
        'id': id,
        'op': op,
        'role': role?.name,
        'stableId': stableId,
      }),
    );
    final prefix = ByteData(4)..setUint32(0, bytes.length);
    socket.add(prefix.buffer.asUint8List());
    socket.add(bytes);
    try {
      await done.future.timeout(const Duration(seconds: 4));
    } finally {
      _commands.remove(id);
    }
  }

  Future<void> _serialize(Future<void> Function() work) {
    final next = _tail.then((_) async {
      if (!_closed) await work();
    });
    _tail = next.catchError((Object e) {
      _fail(e);
    });
    return _tail;
  }

  @override
  Future<void> assign(CameraRole role, String stableId) => _serialize(() async {
    if (role != CameraRole.rear) {
      throw ArgumentError('Only Rear assignment is exposed in this pass');
    }
    if (!_devices.any((d) => d.stableId == stableId)) {
      throw ArgumentError('Select a discovered stable capture identity');
    }
    if (_desired != null) await _stop();
    await _settings.set(AppSettingKeys.cameraRear, stableId);
    _assignments[role] = stableId;
    _publish();
  });
  @override
  Future<void> start(CameraRole role) {
    final epoch = ++_requestEpoch;
    return _serialize(() async {
      if (epoch != _requestEpoch) return;
      await initialize();
      if (!_available || epoch != _requestEpoch) return;
      final id = _assignments[role];
      if (id == null) return;
      _desired = role;
      _state = CameraStreamState.starting;
      _error = null;
      _frame = {};
      _lastFrame = null;
      _publish();
      await _command('start', role: role, stableId: id);
    });
  }

  Future<void> _stop() async {
    _desired = null;
    _state = CameraStreamState.idle;
    _frame = {};
    _lastFrame = null;
    _error = null;
    _publish();
    if (_socket != null) {
      try {
        await _command('stop');
      } on Object {
        await _terminate();
        rethrow;
      }
    }
  }

  @override
  Future<void> stop() {
    ++_requestEpoch;
    return _serialize(_stop);
  }

  @override
  Future<void> refresh() => _serialize(() async {
    await initialize();
    if (_available) await _command('refresh');
  });
  Future<void> _terminate() async {
    _socket?.destroy();
    _socket = null;
    final p = _process;
    if (p != null) {
      try {
        await p.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        p.kill(ProcessSignal.sigterm);
        try {
          await p.exitCode.timeout(const Duration(seconds: 2));
        } on TimeoutException {
          p.kill(ProcessSignal.sigkill);
          await p.exitCode.timeout(const Duration(seconds: 2));
        }
      }
      _process = null;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    ++_requestEpoch;
    // Let in-flight startup finish before closing its owner socket.
    await _tail;
    await _initializing;
    _closed = true;
    Object? failure;
    try {
      if (_socket != null) await _command('close');
    } on Object catch (e) {
      failure = e;
    }
    await _terminate();
    final dir = _directory;
    if (dir != null && await dir.exists()) await dir.delete(recursive: true);
    // Factory stays loaded until process exit: retained platform views may dispose later.
    await _events.close();
    if (failure != null) {
      throw StateError(
        'Camera shutdown required process termination: $failure',
      );
    }
  }
}

/// Bounded incremental parser shared by tests and the actual control connection.
final class CameraControlDecoder {
  final List<int> _bytes = [];
  Iterable<Map<String, dynamic>> add(List<int> incoming) sync* {
    for (final byte in incoming) {
      _bytes.add(byte);
      if (_bytes.length < 4) continue;
      final size =
          (_bytes[0] << 24) | (_bytes[1] << 16) | (_bytes[2] << 8) | _bytes[3];
      if (size <= 0 || size > 16384) {
        throw const FormatException('Camera IPC length exceeds limit');
      }
      if (_bytes.length == size + 4) {
        final value = jsonDecode(utf8.decode(_bytes.sublist(4)));
        _bytes.clear();
        yield Map<String, dynamic>.from(value as Map);
      }
    }
  }
}
