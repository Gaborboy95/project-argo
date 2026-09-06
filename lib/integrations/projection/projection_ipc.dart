import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

abstract final class ProjectionIpcProtocol {
  static const int magic = 0x4152474f; // ARGO
  static const int version = 3;
  static const int headerBytes = 12;
  static const int maximumPayloadBytes = 64 * 1024;
  static const int maximumBufferedBytes = 256 * 1024;
}

enum ProjectionIpcKind {
  hello(1),
  device(2),
  session(3),
  videoStream(4),
  audioStream(5),
  error(6),
  deviceRemoved(7),
  sessionRemoved(8),
  capabilities(9),
  configuration(10),
  metadata(11),
  configure(28),
  connect(20),
  disconnect(21),
  activate(22),
  touch(23),
  button(24),
  rotary(25),
  videoVisibility(26),
  audioGain(27);

  const ProjectionIpcKind(this.wireValue);
  final int wireValue;

  static ProjectionIpcKind? tryParse(int value) {
    for (final kind in values) {
      if (kind.wireValue == value) return kind;
    }
    return null;
  }
}

final class ProjectionIpcMessage {
  const ProjectionIpcMessage(this.kind, [this.payload = const <int>[]]);
  final ProjectionIpcKind kind;
  final List<int> payload;
}

final class ProjectionIpcCodec {
  const ProjectionIpcCodec();

  Uint8List encode(ProjectionIpcMessage message) {
    if (message.payload.length > ProjectionIpcProtocol.maximumPayloadBytes) {
      throw RangeError.value(
        message.payload.length,
        'payload.length',
        'Projection IPC payload exceeds the configured bound',
      );
    }
    final output = ByteData(
      ProjectionIpcProtocol.headerBytes + message.payload.length,
    );
    output.setUint32(0, ProjectionIpcProtocol.magic);
    output.setUint16(4, ProjectionIpcProtocol.version);
    output.setUint16(6, message.kind.wireValue);
    output.setUint32(8, message.payload.length);
    output.buffer.asUint8List().setRange(
      ProjectionIpcProtocol.headerBytes,
      output.lengthInBytes,
      message.payload,
    );
    return output.buffer.asUint8List();
  }
}

final class ProjectionIpcDecoder {
  final List<int> _buffer = [];

  List<ProjectionIpcMessage> add(List<int> bytes) {
    if (_buffer.length + bytes.length >
        ProjectionIpcProtocol.maximumBufferedBytes) {
      _buffer.clear();
      throw const FormatException('Projection IPC receive buffer exceeded.');
    }
    _buffer.addAll(bytes);
    final messages = <ProjectionIpcMessage>[];
    while (_buffer.length >= ProjectionIpcProtocol.headerBytes) {
      final header = ByteData.sublistView(Uint8List.fromList(_buffer), 0, 12);
      if (header.getUint32(0) != ProjectionIpcProtocol.magic) {
        _buffer.clear();
        throw const FormatException('Invalid projection IPC magic.');
      }
      if (header.getUint16(4) != ProjectionIpcProtocol.version) {
        _buffer.clear();
        throw const FormatException(
          'Incompatible projection IPC version; use matching Argo/daemon IPC v3 builds.',
        );
      }
      final kind = ProjectionIpcKind.tryParse(header.getUint16(6));
      if (kind == null) {
        _buffer.clear();
        throw const FormatException('Unknown projection IPC message kind.');
      }
      final length = header.getUint32(8);
      if (length > ProjectionIpcProtocol.maximumPayloadBytes) {
        _buffer.clear();
        throw const FormatException('Projection IPC payload exceeds limit.');
      }
      final frameLength = ProjectionIpcProtocol.headerBytes + length;
      if (_buffer.length < frameLength) break;
      messages.add(
        ProjectionIpcMessage(
          kind,
          List<int>.unmodifiable(
            _buffer.sublist(ProjectionIpcProtocol.headerBytes, frameLength),
          ),
        ),
      );
      _buffer.removeRange(0, frameLength);
    }
    return messages;
  }
}

abstract interface class ProjectionControlTransport {
  Stream<ProjectionIpcMessage> get messages;
  Future<void> send(ProjectionIpcMessage message);
  Future<void> close();
}

typedef ProjectionControlTransportFactory =
    Future<ProjectionControlTransport> Function(String socketPath);

final class UnixProjectionControlTransport
    implements ProjectionControlTransport {
  UnixProjectionControlTransport._(this._socket) {
    _subscription = _socket.listen(
      (bytes) {
        try {
          for (final message in _decoder.add(bytes)) {
            _messages.add(message);
          }
        } on Object catch (error, stackTrace) {
          _messages.addError(error, stackTrace);
          unawaited(close());
        }
      },
      onError: _messages.addError,
      onDone: _messages.close,
      cancelOnError: true,
    );
  }

  static Future<ProjectionControlTransport> connect(String socketPath) async {
    final address = InternetAddress(socketPath, type: InternetAddressType.unix);
    final socket = await Socket.connect(address, 0);
    return UnixProjectionControlTransport._(socket);
  }

  final Socket _socket;
  final ProjectionIpcDecoder _decoder = ProjectionIpcDecoder();
  final ProjectionIpcCodec _codec = const ProjectionIpcCodec();
  final StreamController<ProjectionIpcMessage> _messages =
      StreamController<ProjectionIpcMessage>.broadcast(sync: true);
  StreamSubscription<List<int>>? _subscription;
  bool _closed = false;
  Future<void> _writeTail = Future<void>.value();

  @override
  Stream<ProjectionIpcMessage> get messages => _messages.stream;

  @override
  Future<void> send(ProjectionIpcMessage message) {
    final bytes = _codec.encode(message);
    final operation = _writeTail.then((_) async {
      if (_closed) throw StateError('Projection IPC transport is closed.');
      _socket.add(bytes);
      await _socket.flush();
    });
    _writeTail = operation.catchError((Object _) {});
    return operation;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription?.cancel();
    await _socket.close();
    if (!_messages.isClosed) await _messages.close();
  }
}

final class ProjectionIpcWriter {
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  void uint8(int value) => _bytes.add([value]);

  void uint16(int value) {
    final data = ByteData(2)..setUint16(0, value);
    _bytes.add(data.buffer.asUint8List());
  }

  void int16(int value) {
    final data = ByteData(2)..setInt16(0, value);
    _bytes.add(data.buffer.asUint8List());
  }

  void float32(double value) {
    final data = ByteData(4)..setFloat32(0, value);
    _bytes.add(data.buffer.asUint8List());
  }

  void uint32(int value) {
    final data = ByteData(4)..setUint32(0, value);
    _bytes.add(data.buffer.asUint8List());
  }

  void string(String value) {
    final encoded = utf8.encode(value);
    if (encoded.length > 4096) {
      throw RangeError.value(encoded.length, 'value', 'IPC string is too long');
    }
    uint16(encoded.length);
    _bytes.add(encoded);
  }

  Uint8List takeBytes() => _bytes.takeBytes();
}

final class ProjectionIpcReader {
  ProjectionIpcReader(List<int> bytes) : _data = Uint8List.fromList(bytes);
  final Uint8List _data;
  int _offset = 0;

  int uint8() => _read(1).getUint8(0);
  int uint64() => _read(8).getUint64(0);
  int uint32() => _read(4).getUint32(0);
  int uint16() => _read(2).getUint16(0);
  int int16() => _read(2).getInt16(0);
  double float32() => _read(4).getFloat32(0);

  String string() {
    final length = uint16();
    final start = _offset;
    _offset += length;
    if (_offset > _data.length) {
      throw const FormatException('Truncated projection IPC string.');
    }
    return utf8.decode(_data.sublist(start, _offset));
  }

  bool get isDone => _offset == _data.length;

  ByteData _read(int count) {
    final start = _offset;
    _offset += count;
    if (_offset > _data.length) {
      throw const FormatException('Truncated projection IPC payload.');
    }
    return ByteData.sublistView(_data, start, _offset);
  }
}
