import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';

import '../settings/app_setting_keys.dart';
import '../settings/settings_service.dart';
import 'camera_service.dart';
import 'surround_jobs.dart';

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
  Timer? _retry, _poll, _renderTimer;
  final _renderLeases = <int>[];
  bool _rendering = false;
  int _viewEpoch = 0;
  int? _renderWidth, _renderHeight;
  Future<void>? _connecting;
  Future<void> _tail = Future.value();
  CameraRole? _desired;
  int? _lease;
  int _id = 0, _epoch = 0;
  bool _closed = false, _polling = false;
  DynamicLibrary? _library;
  void Function(int)? _nativeRole;
  int Function(Pointer<Utf8>, int, int)? _nativeImage;
  int Function()? _monotonicNs;
  Map<String, dynamic> Function()? renderingMeasurements;
  Map<String, Object?> _orbit = const {
    'azimuth_rad': -2.3,
    'elevation_rad': 0.9,
    'distance_m': 9.0,
  };
  @override
  CameraSnapshot get current => _current;
  @override
  Stream<CameraSnapshot> get changes => _events.stream;
  String get _directory =>
      _environment['SURROUND_RUNTIME_DIR'] ??
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
        final library = DynamicLibrary.open(path);
        _nativeRole = library
            .lookupFunction<Void Function(Uint32), void Function(int)>(
              'argo_surround_camera_view_set_role',
            );
        _nativeImage = library
            .lookupFunction<
              Int32 Function(Pointer<Utf8>, Uint64, Uint32),
              int Function(Pointer<Utf8>, int, int)
            >('argo_surround_camera_view_set_image');
        _monotonicNs = library
            .lookupFunction<Uint64 Function(), int Function()>(
              'argo_surround_camera_monotonic_ns',
            );
        final result = library.lookupFunction<Int32 Function(), int Function()>(
          'argo_surround_camera_view_register',
        )();
        if (result != 0) {
          throw StateError(
            'External camera factory registration failed ($result)',
          );
        }
        _library = library;
      }
      if (registerNative) {
        final runtime = _directory.toNativeUtf8();
        try {
          if (_library!.lookupFunction<
                Int32 Function(Pointer<Utf8>),
                int Function(Pointer<Utf8>)
              >('argo_surround_camera_runtime_check')(runtime) !=
              0) {
            throw StateError(
              'Surround-camera runtime must be private and owned by this account',
            );
          }
        } finally {
          calloc.free(runtime);
        }
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
              SurroundControlDecoder.validateEnvelope(message);
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
    if (operation == 'orbit') {
      final azimuth = arguments['azimuth_rad'] as num?,
          elevation = arguments['elevation_rad'] as num?,
          distance = arguments['distance_m'] as num?;
      if (azimuth == null ||
          !azimuth.isFinite ||
          elevation == null ||
          !elevation.isFinite ||
          elevation < .15 ||
          elevation > 1.5 ||
          distance == null ||
          !distance.isFinite ||
          distance < 3 ||
          distance > 30) {
        throw ArgumentError(
          'Orbit bounds: finite azimuth, elevation 0.15–1.5 radians and range 3–30 metres',
        );
      }
      _orbit = Map<String, Object?>.from(arguments);
      return {'updated': true};
    }
    if (operation == 'present') {
      if (_nativeImage == null) {
        throw StateError('Native presentation unavailable');
      }
      _renderWidth = arguments['width'] as int?;
      _renderHeight = arguments['height'] as int?;
      final path = ('${arguments['path'] ?? ''}').toNativeUtf8();
      try {
        if (_nativeImage!(
              path,
              arguments['capture_ns'] as int? ?? 0,
              arguments['timeline'] == 'replay' ? 1 : 0,
            ) !=
            0) {
          throw StateError('Invalid completed image path');
        }
      } finally {
        calloc.free(path);
      }
      return {'queued': true, 'native_submission': 'unverified'};
    }
    if (administration) {
      final result = await _admin(operation, arguments);
      if (operation == 'recording' || operation == 'perception') {
        if (result['ok'] == false) throw StateError('${result['error']}');
        if (result['result'] is Map) {
          return Map<String, dynamic>.from(result['result'] as Map);
        }
      }
      return result;
    }
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
            SurroundControlDecoder.validateEnvelope(message);
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
      width: _renderWidth ?? frame['width'] as int?,
      height: _renderHeight ?? frame['height'] as int?,
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
    _renderWidth = _renderHeight = null;
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
    if (epoch == _epoch) _lease = result['subscription_id'] as int;
    await _refresh();
  }

  @override
  Future<void> start(CameraRole role) {
    _desired = role;
    _renderTimer?.cancel();
    ++_viewEpoch;
    return _serialize(() async {
      await initialize();
      if (_socket != null && _desired == role && _lease == null) {
        await _subscribe(role);
      } else if (_socket != null && _desired == role) {
        await _subscribe(role);
      }
    });
  }

  @override
  Future<void> stop() {
    _desired = null;
    _renderTimer?.cancel();
    ++_viewEpoch;
    return _serialize(() async {
      for (final lease in _renderLeases) {
        if (_socket != null) {
          await command('unsubscribe', {'subscription_id': lease});
        }
      }
      _renderLeases.clear();
      _nativeRole?.call((_desired ?? CameraRole.rear).index);
      _renderWidth = _renderHeight = null;
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
  Future<void> selectView(
    String mode, {
    String? group,
    int? width,
    int? height,
  }) async {
    _renderTimer?.cancel();
    final epoch = ++_viewEpoch;
    _nativeRole?.call((_desired ?? CameraRole.rear).index);
    _renderWidth = _renderHeight = null;
    for (final lease in _renderLeases) {
      await command('unsubscribe', {'subscription_id': lease});
    }
    _renderLeases.clear();
    if (mode == 'direct') return;
    if (!{'rectified', 'top_down', 'bowl', 'split'}.contains(mode)) {
      throw ArgumentError('Unsupported view mode');
    }
    final ids = group == null
        ? _current.assignments.values.toSet().toList()
        : _current.groups[group] ?? <String>[];
    for (final id in ids) {
      final lease = await command('subscribe', {
        'camera_id': id,
        'formats': ['BGRx'],
        'consumer': 'display',
        'delivery': 'latest',
        'max_outstanding': 1,
      });
      _renderLeases.add(lease['subscription_id'] as int);
    }
    Map<String, dynamic>? cachedCalibration;
    String? cachedRevision;
    Future<void> render() async {
      if (_rendering || _closed || epoch != _viewEpoch) return;
      _rendering = true;
      try {
        final revision = _current.details['active_calibration'] as String?;
        if (cachedCalibration == null || cachedRevision != revision) {
          final inspected = await SurroundJob(this)
              .run('calibration', {'op': 'inspect'});
          cachedCalibration = inspected['calibration'] == null
              ? null
              : Map<String, dynamic>.from(inspected['calibration'] as Map);
          cachedRevision = revision;
        }
        final calibration = cachedCalibration;
        if (calibration == null) {
          throw StateError('Calibrate a rig before surround rendering');
        }
        final frames = <Map<String, dynamic>>[];
        for (final id in ids) {
          try {
            final snapshot = await command('snapshot', {
              'camera_id': id,
              'ephemeral': true,
            }, true);
            final frame = Map<String, dynamic>.from(snapshot['frame'] as Map);
            frames.add({
              ...frame,
              'path': snapshot['path'],
              'pixel_format': 'image',
              'signal_validity': frame['signal'] ?? 'unknown',
            });
          } on Object {
            /* Renderer marks the absent camera coverage explicitly. */
          }
        }
        if (frames.isEmpty) {
          throw StateError('No fresh source frames for surround view');
        }
        final output =
            '${File(frames.first['path'] as String).parent.path}/argo-surround-$pid.png';
        final measurements =
            renderingMeasurements?.call() ?? <String, dynamic>{};
        final now = _monotonicNs?.call();
        final steering = measurements['steering'] as Map?;
        final pdc = measurements['pdc'] as Map?;
        final viewportWidth = (width ?? _current.width ?? 640).clamp(64, 3840);
        final viewportHeight = (height ?? _current.height ?? 480).clamp(
          64,
          2160,
        );
        const renderBudget = 128 * 1024 * 1024;
        final inputBytes = frames.fold<int>(
          0,
          (sum, frame) =>
              sum + (frame['width'] as int) * (frame['height'] as int) * 3,
        );
        final outputPixels = math.max(
          4096,
          (renderBudget - inputBytes) ~/ (64 + 12 * frames.length),
        );
        final scale = math.min(
          1.0,
          math.sqrt(outputPixels / (viewportWidth * viewportHeight)),
        );
        final rendered = await SurroundJob(this).run('render', {
          'op': 'render',
          'calibration': calibration,
          'frames': frames,
          'view': mode,
          'orbit': _orbit,
          if (measurements['reverse'] is bool)
            'reverse': measurements['reverse'],
          'camera_id': _current.assignments[_desired],
          'output': output,
          'width': (viewportWidth * scale).floor().clamp(64, 3840),
          'height': (viewportHeight * scale).floor().clamp(64, 2160),
          'max_render_memory_mb': 128,
          'timeline': 'live',
          'backend': 'software',
          if (now != null &&
              steering != null &&
              measurements['reverse'] is bool)
            'telemetry': {
              'road_wheel_angle_rad': steering['road_wheel_angle_rad'],
              'timestamp_ns': now - (steering['age_ns'] as int),
              'clock_source': 'CLOCK_MONOTONIC_source_age_mapping',
              'clock_uncertainty_ns': null,
            },
          if (now != null && pdc != null)
            'pdc': [
              for (final observation in pdc['observations'] as List)
                {
                  ...Map<String, dynamic>.from(observation as Map),
                  'timestamp_ns': now - (pdc['age_ns'] as int),
                },
            ],
        });
        if (epoch == _viewEpoch && !_closed) {
          final stamps = frames.map((f) => f['capture_ns'] as int).toList()
            ..sort();
          await command('present', {
            'path': rendered['output'],
            'capture_ns': stamps.first,
            'timeline': 'live',
            'width': rendered['width'],
            'height': rendered['height'],
          });
        }
      } on Object catch (error) {
        if (epoch == _viewEpoch) _unavailable(error);
      } finally {
        _rendering = false;
      }
    }

    await render();
    if (epoch == _viewEpoch && !_closed) {
      _renderTimer = Timer.periodic(
        const Duration(milliseconds: 100),
        (_) => unawaited(render()),
      );
    }
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

  static void validateEnvelope(Map<String, dynamic> value) {
    if (value['major'] != 1 ||
        value['minor'] is! int ||
        (value['minor'] as int) < 0 ||
        (value['minor'] as int) > 65535 ||
        value['id'] is! int ||
        (value['id'] as int) < 0) {
      throw const FormatException(
        'Incompatible or malformed surround-camera envelope',
      );
    }
    if (value.containsKey('ok')) {
      if (value['ok'] is! bool)
        throw const FormatException('Invalid response status');
    } else if (value['op'] is! String || value['args'] is! Map) {
      throw const FormatException('Invalid request envelope');
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
