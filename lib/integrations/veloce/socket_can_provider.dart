import 'dart:async';
import 'dart:collection';
import 'dart:developer' as developer;
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:veloce_lua_core/veloce_lua_core.dart';

/// Linux SocketCAN settings selected explicitly through the environment.
final class SocketCanConfiguration {
  SocketCanConfiguration({
    required this.interfaceName,
    required this.logicalBus,
    this.writesEnabled = false,
    this.maxPendingPerSubscription = 32,
  }) {
    if (interfaceName.isEmpty ||
        interfaceName.length >= _interfaceNameSize ||
        interfaceName.contains('/') ||
        interfaceName.contains('\u0000')) {
      throw ArgumentError.value(
        interfaceName,
        'interfaceName',
        'Must be a valid Linux network interface name',
      );
    }
    if (logicalBus.isEmpty ||
        logicalBus.length > 64 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(logicalBus)) {
      throw ArgumentError.value(logicalBus, 'logicalBus', 'Invalid CAN bus');
    }
    if (maxPendingPerSubscription <= 0) {
      throw ArgumentError.value(
        maxPendingPerSubscription,
        'maxPendingPerSubscription',
        'Must be positive',
      );
    }
  }

  /// Returns `null` unless SocketCAN was explicitly selected.
  static SocketCanConfiguration? fromEnvironment(
    Map<String, String> environment,
  ) {
    final mode = environment['VELOCE_CAN_INPUT']?.trim().toLowerCase();
    if (mode != 'socketcan') return null;

    return SocketCanConfiguration(
      interfaceName: _valueOrDefault(
        environment,
        'VELOCE_SOCKETCAN_INTERFACE',
        'can0',
      ),
      logicalBus: _valueOrDefault(environment, 'VELOCE_CAN_BUS', 'comfort'),
      writesEnabled: _boolean(
        environment,
        'VELOCE_CAN_WRITE_ENABLED',
        defaultValue: false,
      ),
    );
  }

  final String interfaceName;
  final String logicalBus;
  final bool writesEnabled;
  final int maxPendingPerSubscription;

  static String _valueOrDefault(
    Map<String, String> environment,
    String name,
    String defaultValue,
  ) {
    final value = environment[name]?.trim();
    return value == null || value.isEmpty ? defaultValue : value;
  }

  static bool _boolean(
    Map<String, String> environment,
    String name, {
    required bool defaultValue,
  }) {
    final raw = environment[name];
    if (raw == null) return defaultValue;
    return switch (raw.trim().toLowerCase()) {
      '1' || 'true' || 'yes' || 'on' => true,
      '0' || 'false' || 'no' || 'off' => false,
      _ => throw ArgumentError.value(raw, name, 'Must be a boolean'),
    };
  }
}

typedef SocketCanErrorHandler = void Function(
  Object error,
  StackTrace stackTrace,
);

/// A production [CanProvider] backed by Linux SocketCAN.
///
/// The worker isolate exclusively owns the native socket and polling loop.
/// Filtering and bounded per-subscriber delivery remain on the host isolate so
/// Lua plugins retain Veloce's owner cleanup and newest-data backpressure
/// semantics.
final class SocketCanProvider implements CanProvider {
  SocketCanProvider._(this.configuration, {required this._onError});

  static Future<SocketCanProvider> start(
    SocketCanConfiguration configuration, {
    SocketCanErrorHandler? onError,
  }) async {
    if (!Platform.isLinux) {
      throw UnsupportedError('SocketCAN is available only on Linux.');
    }

    final provider = SocketCanProvider._(configuration, onError: onError);
    try {
      await provider._startWorker();
      return provider;
    } on Object {
      await provider.close();
      rethrow;
    }
  }

  final SocketCanConfiguration configuration;
  final SocketCanErrorHandler? _onError;
  final ReceivePort _messages = ReceivePort();
  final ReceivePort _errors = ReceivePort();
  final ReceivePort _exits = ReceivePort();
  final Completer<SendPort> _ready = Completer<SendPort>();
  final Completer<void> _exited = Completer<void>();
  final Map<int, Completer<void>> _pendingCommands = {};
  final Map<int, _SocketCanSubscription> _subscriptions = {};

  late final StreamSubscription<Object?> _messageSubscription;
  late final StreamSubscription<Object?> _errorSubscription;
  late final StreamSubscription<Object?> _exitSubscription;
  Isolate? _worker;
  SendPort? _commands;
  Future<void>? _closeFuture;
  var _nextCommandId = 1;
  var _nextSubscriptionId = 1;
  var _closing = false;
  var _closed = false;
  Object? _workerFailure;

  @override
  bool get writesEnabled => configuration.writesEnabled;

  Future<void> _startWorker() async {
    _messageSubscription = _messages.listen(_handleWorkerMessage);
    _errorSubscription = _errors.listen(_handleWorkerIsolateError);
    _exitSubscription = _exits.listen((_) => _handleWorkerExit());
    try {
      _worker = await Isolate.spawn<Map<String, Object?>>(
        _socketCanWorkerMain,
        {
          'hostPort': _messages.sendPort,
          'interfaceName': configuration.interfaceName,
          'logicalBus': configuration.logicalBus,
          'writesEnabled': configuration.writesEnabled,
        },
        debugName: 'argo:socketcan:${configuration.interfaceName}',
        onError: _errors.sendPort,
        onExit: _exits.sendPort,
        errorsAreFatal: true,
      );
      final commands = await _ready.future;
      if (_exited.isCompleted || _workerFailure != null) {
        throw StateError('SocketCAN worker stopped during startup.');
      }
      _commands = commands;
    } on Object {
      if (_worker == null && !_exited.isCompleted) _exited.complete();
      rethrow;
    }
  }

  @override
  Future<CanSubscription> subscribe({
    required String ownerId,
    required CanFilter filter,
    required CanFrameHandler onFrame,
  }) async {
    _ensureOpen();
    _validateOwner(ownerId);
    final id = _nextSubscriptionId++;
    final subscription = _SocketCanSubscription(
      id: id,
      ownerId: ownerId,
      filter: filter,
      handler: onFrame,
      maxPending: configuration.maxPendingPerSubscription,
      reportError: _reportSubscriptionError,
      onCancel: () => _subscriptions.remove(id),
    );
    _subscriptions[id] = subscription;
    return subscription;
  }

  @override
  Future<void> send({required String ownerId, required CanFrame frame}) {
    _ensureOpen();
    _validateOwner(ownerId);
    if (!writesEnabled) {
      return Future.error(CanWriteDisabledException(pluginId: ownerId));
    }
    if (frame.isError) {
      return Future.error(
        ArgumentError('Controller error frames cannot be transmitted.'),
      );
    }
    if (frame.bus != configuration.logicalBus) {
      return Future.error(
        ArgumentError.value(frame.bus, 'bus', 'Wrong logical CAN bus'),
      );
    }
    return _command('send', {'frame': _encodeSocketCanFrame(frame)});
  }

  @override
  Future<void> removeOwner(String ownerId) async {
    final subscriptions = _subscriptions.values
        .where((subscription) => subscription.ownerId == ownerId)
        .toList(growable: false);
    await Future.wait(
      subscriptions.map((subscription) => subscription.cancel()),
    );
  }

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    if (_closed) return;
    _closing = true;
    final commands = _commands;
    if (commands != null && !_exited.isCompleted) {
      try {
        await _command('close', const {}, allowClosing: true);
      } on Object catch (error, stackTrace) {
        if (!_exited.isCompleted) _reportError(error, stackTrace);
      }
    } else if (!_exited.isCompleted) {
      _worker?.kill(priority: Isolate.immediate);
    }
    await _exited.future;

    final subscriptions = _subscriptions.values.toList(growable: false);
    _subscriptions.clear();
    await Future.wait(
      subscriptions.map((subscription) => subscription.cancel()),
    );
    _failPendingCommands(StateError('SocketCAN provider is closed.'));

    await _messageSubscription.cancel();
    await _errorSubscription.cancel();
    await _exitSubscription.cancel();
    _messages.close();
    _errors.close();
    _exits.close();
    _commands = null;
    _worker = null;
    _closed = true;
  }

  Future<void> _command(
    String operation,
    Map<String, Object?> payload, {
    bool allowClosing = false,
  }) {
    if (_closed || (_closing && !allowClosing)) {
      return Future.error(StateError('SocketCAN provider is closing.'));
    }
    final commands = _commands;
    if (commands == null) {
      return Future.error(StateError('SocketCAN worker is unavailable.'));
    }
    final id = _nextCommandId++;
    final completer = Completer<void>();
    _pendingCommands[id] = completer;
    commands.send({
      'type': 'command',
      'id': id,
      'operation': operation,
      ...payload,
    });
    return completer.future;
  }

  void _handleWorkerMessage(Object? raw) {
    if (raw is! Map<Object?, Object?>) return;
    switch (raw['type']) {
      case 'ready':
        final commands = raw['commands'];
        if (commands is SendPort && !_ready.isCompleted) {
          _commands = commands;
          _ready.complete(commands);
        }
      case 'frames':
        final batchId = raw['batchId'];
        final frames = raw['frames'];
        if (batchId is! int || frames is! List<Object?>) return;
        try {
          for (final encoded in frames) {
            final frame = _decodeSocketCanFrame(encoded);
            if (frame != null) _dispatch(frame);
          }
        } finally {
          _commands?.send({'type': 'frameAck', 'batchId': batchId});
        }
      case 'response':
        final id = raw['id'];
        if (id is! int) return;
        final completer = _pendingCommands.remove(id);
        if (completer == null) return;
        if (raw['ok'] == true) {
          completer.complete();
        } else {
          completer.completeError(StateError('${raw['error']}'));
        }
      case 'startupError':
        final error = StateError('${raw['error']}');
        if (!_ready.isCompleted) _ready.completeError(error);
      case 'workerError':
        final error = StateError('${raw['error']}');
        final stackTrace = StackTrace.fromString('${raw['stackTrace'] ?? ''}');
        _workerFailure = error;
        _reportError(error, stackTrace);
    }
  }

  void _handleWorkerIsolateError(Object? raw) {
    final message = raw is List && raw.isNotEmpty ? '${raw.first}' : '$raw';
    final stackTrace = raw is List && raw.length > 1
        ? StackTrace.fromString('${raw[1]}')
        : StackTrace.current;
    final error = StateError('SocketCAN worker isolate failed: $message');
    _workerFailure = error;
    if (!_ready.isCompleted) _ready.completeError(error, stackTrace);
    _reportError(error, stackTrace);
  }

  void _handleWorkerExit() {
    _commands = null;
    if (!_ready.isCompleted) {
      _ready.completeError(
        StateError('SocketCAN worker exited during startup.'),
      );
    }
    if (!_exited.isCompleted) _exited.complete();
    final error = StateError('SocketCAN worker exited.');
    _failPendingCommands(error);
    if (!_closing) {
      final unexpected = StateError('SocketCAN worker exited unexpectedly.');
      _workerFailure ??= unexpected;
      _reportError(unexpected, StackTrace.current);
    }
  }

  void _dispatch(CanFrame frame) {
    if (_closing || _closed) return;
    for (final subscription in List.of(_subscriptions.values)) {
      if (subscription.active && subscription.filter.matches(frame)) {
        subscription.enqueue(frame);
      }
    }
  }

  void _failPendingCommands(Object error) {
    for (final completer in _pendingCommands.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pendingCommands.clear();
  }

  void _reportSubscriptionError(
    Object error,
    StackTrace stackTrace,
    String ownerId,
  ) {
    _reportError(
      StateError('SocketCAN subscriber $ownerId failed: $error'),
      stackTrace,
    );
  }

  void _reportError(Object error, StackTrace stackTrace) {
    try {
      final handler = _onError;
      if (handler != null) {
        handler(error, stackTrace);
      } else {
        developer.log(
          error.toString(),
          name: 'argo.veloce.socketcan',
          error: error,
          stackTrace: stackTrace,
        );
      }
    } on Object {
      // Diagnostics must not break CAN delivery or cleanup.
    }
  }

  void _ensureOpen() {
    if (_closing || _closed) {
      throw StateError('SocketCAN provider is closed.');
    }
    if (_commands == null || _exited.isCompleted || _workerFailure != null) {
      throw StateError('SocketCAN worker is unavailable.');
    }
  }

  static void _validateOwner(String ownerId) {
    if (ownerId.trim().isEmpty) {
      throw ArgumentError.value(ownerId, 'ownerId', 'Must not be empty');
    }
  }
}

final class _SocketCanSubscription implements CanSubscription {
  _SocketCanSubscription({
    required this.id,
    required this.ownerId,
    required this.filter,
    required this.handler,
    required this.maxPending,
    required this.reportError,
    required this.onCancel,
  });

  final int id;
  @override
  final String ownerId;
  @override
  final CanFilter filter;
  final CanFrameHandler handler;
  final int maxPending;
  final CanProviderErrorHandler? reportError;
  final void Function() onCancel;
  final Queue<CanFrame> _pending = Queue<CanFrame>();
  Future<void>? _drainFuture;
  bool active = true;

  bool enqueue(CanFrame frame) {
    if (!active) return false;
    final accepted = _pending.length < maxPending;
    if (!accepted) _pending.removeFirst();
    _pending.addLast(frame.copyWith());
    _startDrain();
    return accepted;
  }

  void _startDrain() {
    if (_drainFuture != null) return;
    final future = _drain();
    _drainFuture = future;
    unawaited(
      future.whenComplete(() {
        _drainFuture = null;
        if (active && _pending.isNotEmpty) _startDrain();
      }),
    );
  }

  Future<void> _drain() async {
    while (active && _pending.isNotEmpty) {
      final frame = _pending.removeFirst();
      try {
        await handler(frame);
      } on Object catch (error, stackTrace) {
        try {
          reportError?.call(error, stackTrace, ownerId);
        } on Object {
          // Error reporters must not break subscription isolation.
        }
      }
    }
  }

  @override
  Future<void> cancel() async {
    if (!active) return;
    active = false;
    _pending.clear();
    onCancel();
    await (_drainFuture ?? Future<void>.value());
  }
}

void _socketCanWorkerMain(Map<String, Object?> initial) async {
  final hostPort = initial['hostPort']! as SendPort;
  final commands = ReceivePort();
  _SocketCanWorker? worker;
  try {
    worker = _SocketCanWorker.open(
      hostPort: hostPort,
      interfaceName: initial['interfaceName']! as String,
      logicalBus: initial['logicalBus']! as String,
      writesEnabled: initial['writesEnabled']! as bool,
      onFatalError: (error, stackTrace) {
        hostPort.send({
          'type': 'workerError',
          'error': error.toString(),
          'stackTrace': stackTrace.toString(),
        });
        commands.close();
      },
    );
    worker.start();
    hostPort.send({'type': 'ready', 'commands': commands.sendPort});
  } on Object catch (error, stackTrace) {
    worker?.close();
    commands.close();
    hostPort.send({'type': 'startupError', 'error': '$error\n$stackTrace'});
    return;
  }

  await for (final raw in commands) {
    if (raw is! Map<Object?, Object?>) continue;
    if (raw['type'] == 'frameAck') {
      final batchId = raw['batchId'];
      if (batchId is int) worker.acknowledgeFrames(batchId);
      continue;
    }
    if (raw['type'] != 'command') continue;
    final id = raw['id'];
    if (id is! int) continue;
    final operation = raw['operation'];
    var shouldClose = false;
    try {
      switch (operation) {
        case 'send':
          worker.send(raw['frame']! as Uint8List);
        case 'close':
          shouldClose = true;
          worker.close();
        default:
          throw StateError('Unknown SocketCAN operation "$operation".');
      }
      hostPort.send({'type': 'response', 'id': id, 'ok': true});
    } on Object catch (error) {
      hostPort.send({
        'type': 'response',
        'id': id,
        'ok': false,
        'error': error.toString(),
      });
    }
    if (shouldClose) {
      commands.close();
      return;
    }
  }
  worker.close();
}

final class _SocketCanWorker {
  _SocketCanWorker._({
    required this.hostPort,
    required this.interfaceName,
    required this.logicalBus,
    required this.writesEnabled,
    required this.onFatalError,
    required this._bindings,
    required this._socket,
    required this._buffer,
  });

  static _SocketCanWorker open({
    required SendPort hostPort,
    required String interfaceName,
    required String logicalBus,
    required bool writesEnabled,
    required void Function(Object error, StackTrace stackTrace) onFatalError,
  }) {
    final bindings = _LinuxSocketBindings.open();
    final name = interfaceName.toNativeUtf8();
    var socket = -1;
    Pointer<Uint8>? buffer;
    try {
      final interfaceIndex = bindings.ifNameToIndex(name);
      if (interfaceIndex == 0) {
        throw FileSystemException(
          'SocketCAN interface does not exist',
          interfaceName,
        );
      }

      socket = bindings.socket(
        _addressFamilyCan,
        _socketRaw | _socketNonBlocking | _socketCloseOnExec,
        _canRawProtocol,
      );
      if (socket < 0) {
        throw FileSystemException(
          'Could not create SocketCAN socket (errno ${bindings.errno})',
          interfaceName,
        );
      }

      final address = calloc<Uint8>(_socketCanAddressSize);
      try {
        address.cast<Uint16>().value = _addressFamilyCan;
        (address + 4).cast<Uint32>().value = interfaceIndex;
        if (bindings.bind(socket, address.cast(), _socketCanAddressSize) != 0) {
          throw FileSystemException(
            'Could not bind SocketCAN socket (errno ${bindings.errno})',
            interfaceName,
          );
        }
      } finally {
        calloc.free(address);
      }

      final enableFd = calloc<Int32>()..value = 1;
      try {
        bindings.setSocketOption(
          socket,
          _socketCanRawLevel,
          _canRawFdFramesOption,
          enableFd.cast(),
          sizeOf<Int32>(),
        );
      } finally {
        calloc.free(enableFd);
      }

      final errorMask = calloc<Uint32>()..value = _canExtendedMask;
      try {
        bindings.setSocketOption(
          socket,
          _socketCanRawLevel,
          _canRawErrorFilterOption,
          errorMask.cast(),
          sizeOf<Uint32>(),
        );
      } finally {
        calloc.free(errorMask);
      }

      buffer = calloc<Uint8>(_canFdFrameSize);
      return _SocketCanWorker._(
        hostPort: hostPort,
        interfaceName: interfaceName,
        logicalBus: logicalBus,
        writesEnabled: writesEnabled,
        onFatalError: onFatalError,
        bindings: bindings,
        socket: socket,
        buffer: buffer,
      );
    } on Object {
      if (buffer != null) calloc.free(buffer);
      if (socket >= 0) bindings.closeSocket(socket);
      rethrow;
    } finally {
      calloc.free(name);
    }
  }

  final SendPort hostPort;
  final String interfaceName;
  final String logicalBus;
  final bool writesEnabled;
  final void Function(Object error, StackTrace stackTrace) onFatalError;
  final _LinuxSocketBindings _bindings;
  int _socket;
  Pointer<Uint8>? _buffer;
  Timer? _poller;
  var _closed = false;
  var _nextBatchId = 1;
  int? _unacknowledgedBatchId;

  void start() {
    if (_closed) throw StateError('SocketCAN worker is closed.');
    _poller = Timer.periodic(
      const Duration(milliseconds: 4),
      (_) => _drainSocket(),
    );
  }

  void _drainSocket() {
    final buffer = _buffer;
    if (_closed ||
        _socket < 0 ||
        buffer == null ||
        _unacknowledgedBatchId != null) {
      return;
    }
    try {
      final frames = <Map<String, Object?>>[];
      for (var received = 0; received < 128; received++) {
        final length = _bindings.receive(
          _socket,
          buffer.cast(),
          _canFdFrameSize,
          0,
        );
        if (length < 0) {
          final errorNumber = _bindings.errno;
          if (errorNumber == _errorTryAgain) break;
          if (errorNumber == _errorInterrupted) continue;
          throw FileSystemException(
            'Could not receive SocketCAN frame (errno $errorNumber)',
            interfaceName,
          );
        }
        if (length == 0) break;
        final frame = _decodeWireFrame(
          buffer.asTypedList(length),
          length: length,
          logicalBus: logicalBus,
        );
        if (frame != null) frames.add(frame);
      }
      if (frames.isNotEmpty) {
        final batchId = _nextBatchId++;
        _unacknowledgedBatchId = batchId;
        hostPort.send({'type': 'frames', 'batchId': batchId, 'frames': frames});
      }
    } on Object catch (error, stackTrace) {
      close();
      onFatalError(error, stackTrace);
    }
  }

  void acknowledgeFrames(int batchId) {
    if (_unacknowledgedBatchId == batchId) {
      _unacknowledgedBatchId = null;
    }
  }

  void send(Uint8List frame) {
    if (_closed || _socket < 0) {
      throw StateError('SocketCAN worker is closed.');
    }
    if (!writesEnabled) {
      throw StateError('SocketCAN transmission is disabled.');
    }
    if (frame.length != _canFrameSize && frame.length != _canFdFrameSize) {
      throw ArgumentError.value(frame.length, 'frame', 'Invalid frame size');
    }
    final buffer = calloc<Uint8>(frame.length);
    try {
      buffer.asTypedList(frame.length).setAll(0, frame);
      final written = _bindings.send(_socket, buffer.cast(), frame.length, 0);
      if (written != frame.length) {
        throw FileSystemException(
          'Could not send SocketCAN frame (errno ${_bindings.errno})',
          interfaceName,
        );
      }
    } finally {
      calloc.free(buffer);
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _poller?.cancel();
    _poller = null;
    final buffer = _buffer;
    _buffer = null;
    if (buffer != null) calloc.free(buffer);
    if (_socket >= 0) _bindings.closeSocket(_socket);
    _socket = -1;
  }
}

Map<String, Object?>? _decodeWireFrame(
  Uint8List bytes, {
  required int length,
  required String logicalBus,
}) {
  if (length != _canFrameSize && length != _canFdFrameSize) return null;
  final data = ByteData.sublistView(bytes);
  final rawId = data.getUint32(0, Endian.host);
  final payloadLength = bytes[4];
  final timestamp = DateTime.now().microsecondsSinceEpoch;

  if ((rawId & _canErrorFlag) != 0) {
    if (length != _canFrameSize || payloadLength > 8) return null;
    return {
      'kind': CanFrameKind.error.index,
      'bus': logicalBus,
      'errorFlags': rawId & _canExtendedMask,
      'data': Uint8List.fromList(bytes.sublist(8, 8 + payloadLength)),
      'timestampMicros': timestamp,
    };
  }

  final extended = (rawId & _canExtendedFlag) != 0;
  final id = rawId & (extended ? _canExtendedMask : _canStandardMask);
  final maximumPayload = length == _canFdFrameSize ? 64 : 8;
  if (payloadLength > maximumPayload) return null;

  if ((rawId & _canRemoteFlag) != 0) {
    if (length != _canFrameSize || payloadLength > 8) return null;
    return {
      'kind': CanFrameKind.remote.index,
      'bus': logicalBus,
      'id': id,
      'remoteLength': payloadLength,
      'extended': extended,
      'timestampMicros': timestamp,
    };
  }

  return {
    'kind': CanFrameKind.data.index,
    'bus': logicalBus,
    'id': id,
    'data': Uint8List.fromList(bytes.sublist(8, 8 + payloadLength)),
    'extended': extended,
    'timestampMicros': timestamp,
  };
}

CanFrame? _decodeSocketCanFrame(Object? raw) {
  if (raw is! Map<Object?, Object?>) return null;
  try {
    final kind = CanFrameKind.values[raw['kind']! as int];
    final bus = raw['bus']! as String;
    final timestamp = raw['timestampMicros']! as int;
    return switch (kind) {
      CanFrameKind.data => CanFrame(
        bus: bus,
        id: raw['id']! as int,
        data: raw['data']! as Uint8List,
        extended: raw['extended']! as bool,
        timestampMicros: timestamp,
      ),
      CanFrameKind.remote => CanFrame.remote(
        bus: bus,
        id: raw['id']! as int,
        remoteLength: raw['remoteLength']! as int,
        extended: raw['extended']! as bool,
        timestampMicros: timestamp,
      ),
      CanFrameKind.error => CanFrame.error(
        bus: bus,
        errorFlags: raw['errorFlags']! as int,
        data: raw['data']! as Uint8List,
        timestampMicros: timestamp,
      ),
    };
  } on Object {
    return null;
  }
}

Uint8List _encodeSocketCanFrame(CanFrame frame) {
  final useFd = frame.isData && frame.length > 8;
  if (frame.isRemote && useFd) {
    throw ArgumentError('CAN-FD does not support RTR frames.');
  }
  final length = useFd ? _canFdFrameSize : _canFrameSize;
  final bytes = Uint8List(length);
  final data = ByteData.sublistView(bytes);
  var rawId = frame.id;
  if (frame.extended) rawId |= _canExtendedFlag;
  if (frame.isRemote) rawId |= _canRemoteFlag;
  data.setUint32(0, rawId, Endian.host);
  bytes[4] = frame.isRemote ? frame.remoteLength! : frame.length;
  if (frame.isData) bytes.setRange(8, 8 + frame.length, frame.data);
  return bytes;
}

final class _LinuxSocketBindings {
  _LinuxSocketBindings(DynamicLibrary library)
    : socket = library.lookupFunction<_SocketNative, _SocketDart>('socket'),
      bind = library.lookupFunction<_BindNative, _BindDart>('bind'),
      receive = library.lookupFunction<_ReceiveNative, _ReceiveDart>('recv'),
      send = library.lookupFunction<_SendNative, _SendDart>('send'),
      setSocketOption = library
          .lookupFunction<_SetSocketOptionNative, _SetSocketOptionDart>(
            'setsockopt',
          ),
      closeSocket = library.lookupFunction<_CloseNative, _CloseDart>('close'),
      ifNameToIndex = library
          .lookupFunction<_IfNameToIndexNative, _IfNameToIndexDart>(
            'if_nametoindex',
          ),
      _errnoLocation = library
          .lookupFunction<_ErrnoLocationNative, _ErrnoLocationDart>(
            '__errno_location',
          );

  factory _LinuxSocketBindings.open() {
    for (final name in const ['libc.so.6', 'libc.so']) {
      try {
        return _LinuxSocketBindings(DynamicLibrary.open(name));
      } on ArgumentError {
        // Try the next conventional libc name.
      }
    }
    throw UnsupportedError('Could not load libc for SocketCAN.');
  }

  final _SocketDart socket;
  final _BindDart bind;
  final _ReceiveDart receive;
  final _SendDart send;
  final _SetSocketOptionDart setSocketOption;
  final _CloseDart closeSocket;
  final _IfNameToIndexDart ifNameToIndex;
  final _ErrnoLocationDart _errnoLocation;

  int get errno => _errnoLocation().value;
}

typedef _SocketNative = Int32 Function(Int32, Int32, Int32);
typedef _SocketDart = int Function(int, int, int);
typedef _BindNative = Int32 Function(Int32, Pointer<Void>, Uint32);
typedef _BindDart = int Function(int, Pointer<Void>, int);
typedef _ReceiveNative = IntPtr Function(Int32, Pointer<Void>, UintPtr, Int32);
typedef _ReceiveDart = int Function(int, Pointer<Void>, int, int);
typedef _SendNative = IntPtr Function(Int32, Pointer<Void>, UintPtr, Int32);
typedef _SendDart = int Function(int, Pointer<Void>, int, int);
typedef _SetSocketOptionNative = Int32 Function(
  Int32,
  Int32,
  Int32,
  Pointer<Void>,
  Uint32,
);
typedef _SetSocketOptionDart = int Function(int, int, int, Pointer<Void>, int);
typedef _CloseNative = Int32 Function(Int32);
typedef _CloseDart = int Function(int);
typedef _IfNameToIndexNative = Uint32 Function(Pointer<Utf8>);
typedef _IfNameToIndexDart = int Function(Pointer<Utf8>);
typedef _ErrnoLocationNative = Pointer<Int32> Function();
typedef _ErrnoLocationDart = Pointer<Int32> Function();

const _interfaceNameSize = 16;
const _addressFamilyCan = 29;
const _socketRaw = 3;
const _socketNonBlocking = 0x800;
const _socketCloseOnExec = 0x80000;
const _canRawProtocol = 1;
const _socketCanRawLevel = 101;
const _canRawFdFramesOption = 5;
const _canRawErrorFilterOption = 2;
const _socketCanAddressSize = 16;
const _canFrameSize = 16;
const _canFdFrameSize = 72;
const _canExtendedFlag = 0x80000000;
const _canRemoteFlag = 0x40000000;
const _canErrorFlag = 0x20000000;
const _canStandardMask = 0x7ff;
const _canExtendedMask = 0x1fffffff;
const _errorInterrupted = 4;
const _errorTryAgain = 11;
