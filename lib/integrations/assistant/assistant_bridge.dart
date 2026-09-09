import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:veloce_lua_core/veloce_lua_core.dart';

import '../../core/audio/audio_service.dart';
import '../../core/audio/audio_types.dart';
import 'assistant_bridge_configuration.dart';
import 'assistant_schema.dart';

/// Authenticated loopback boundary for the separate voice process.
/// It grants no CAN access and never impersonates a vehicle integration plugin.
final class AssistantBridge {
  AssistantBridge._({
    required this.configuration,
    required this.eventBus,
    required this.vehicleDataBus,
    required this.audio,
    required this.isPluginLoaded,
    required this._now,
  });

  static const sourceId = 'argo.assistant';
  static const _audioKeys = {'audio.volume', 'audio.muted', 'audio.available'};
  final AssistantBridgeConfiguration configuration;
  final PluginEventBus eventBus;
  final VehicleDataBus vehicleDataBus;
  final AudioService audio;
  final bool Function(String) isPluginLoaded;
  final DateTime Function() _now;
  final _random = Random.secure();
  final List<PluginEventSubscription> _subscriptions = [];
  final Queue<Map<String, Object?>> _events = Queue();
  final Map<String, _Command> _commands = {};
  final LinkedHashMap<String, _Execution> _requests = LinkedHashMap();
  final Set<Future<void>> _pendingHttp = {};
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _httpSubscription;
  String? _sessionId;
  DateTime? _expiresAt;
  Timer? _sessionTimer;
  AudioFocusHandle? _focus;
  Future<void> _focusTail = Future.value();
  int _eventSequence = 0;
  int _activeRequests = 0;
  bool _closed = false;
  bool _sourceRegistered = false;
  Future<void>? _closeFuture;

  int get port => _server!.port;
  bool get isClosed => _closed;

  static Future<AssistantBridge> start({
    required AssistantBridgeConfiguration configuration,
    required PluginEventBus eventBus,
    required VehicleDataBus vehicleDataBus,
    required AudioService audio,
    required bool Function(String) isPluginLoaded,
    DateTime Function()? now,
  }) async {
    final bridge = AssistantBridge._(
      configuration: configuration,
      eventBus: eventBus,
      vehicleDataBus: vehicleDataBus,
      audio: audio,
      isPluginLoaded: isPluginLoaded,
      now: now ?? DateTime.now,
    );
    try {
      await audio.registerSource(
        AudioSource(id: sourceId, role: AudioSourceRole.communication),
      );
      bridge._sourceRegistered = true;
      bridge._registerCommands();
      for (final topic in configuration.eventTopics) {
        bridge._subscriptions.add(
          eventBus.subscribe(
            ownerId: sourceId,
            topic: topic,
            handler: (event) {
              if (bridge._closed) return;
              bridge._events.add({
                'sequence': ++bridge._eventSequence,
                'topic': event.topic,
                'data': event.data,
                'timestamp': event.timestamp.toIso8601String(),
                'source_id': event.sourcePluginId,
              });
              if (bridge._events.length > 128) bridge._events.removeFirst();
            },
          ),
        );
      }
      bridge._server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        configuration.port,
        shared: false,
      );
      bridge._server!.idleTimeout = const Duration(seconds: 5);
      bridge._httpSubscription = bridge._server!.listen((request) {
        final future = bridge._handle(request);
        bridge._pendingHttp.add(future);
        unawaited(
          future.whenComplete(() => bridge._pendingHttp.remove(future)),
        );
      });
      return bridge;
    } on Object {
      try {
        await bridge.close();
      } on Object {
        // Keep the startup failure while attempting all resource cleanup.
      }
      rethrow;
    }
  }

  void _registerCommands() {
    void audioCommand(
      String name,
      String description,
      Map<String, Object?> properties,
      bool Function() available,
      Future<void> Function(Map<String, Object?>) execute,
    ) {
      _commands[name] = _Command(
        name: name,
        description: description,
        parameters: AssistantSchema(assistantObjectSchema(properties)),
        available: available,
        semantics: 'audio_backend_applied',
        execute: (arguments, requestId) async {
          if (!available()) {
            throw const _BridgeError(
              503,
              'unavailable',
              'Audio backend does not support this command.',
            );
          }
          await execute(arguments);
          return {'status': 'succeeded', 'result': _audioState()};
        },
      );
    }

    bool volumeAvailable() =>
        audio.current.backendAvailable &&
        audio.current.capabilities.masterVolume;
    bool muteAvailable() =>
        audio.current.backendAvailable && audio.current.capabilities.mute;
    audioCommand(
      'audio.set_volume',
      'Set audio volume from 0 to 1.',
      {
        'value': {'type': 'number', 'minimum': 0, 'maximum': 1},
      },
      volumeAvailable,
      (args) => audio.setMasterVolume((args['value'] as num).toDouble()),
    );
    audioCommand(
      'audio.set_muted',
      'Set whether audio is muted.',
      {
        'muted': {'type': 'boolean'},
      },
      muteAvailable,
      (args) => audio.setMuted(args['muted'] as bool),
    );
    audioCommand(
      'audio.volume_step',
      'Change audio volume by one configured step.',
      {
        'direction': {
          'type': 'string',
          'enum': ['up', 'down'],
        },
      },
      volumeAvailable,
      (args) => audio.volumeStep(
        args['direction'] == 'up'
            ? AudioVolumeDirection.up
            : AudioVolumeDirection.down,
      ),
    );
    for (final entry in configuration.writableData.entries) {
      final name = 'data.write.${entry.key}';
      _commands[name] = _Command(
        name: name,
        description:
            'Publish the configured data value ${entry.key}. This does not confirm hardware actuation.',
        parameters: AssistantSchema(
          assistantObjectSchema({'value': entry.value.json}),
        ),
        available: () => true,
        semantics: 'data_published_only',
        execute: (args, requestId) async {
          vehicleDataBus.publish(
            entry.key,
            args['value'],
            sourcePluginId: sourceId,
          );
          return {
            'status': 'published',
            'result': {'key': entry.key, 'actuation_confirmed': false},
          };
        },
      );
    }
    for (final entry in configuration.publishEvents.entries) {
      final name = 'event.publish.${entry.key}';
      _commands[name] = _Command(
        name: name,
        description:
            'Publish the configured event ${entry.key}. This does not confirm hardware actuation.',
        parameters: AssistantSchema(
          assistantObjectSchema({'data': entry.value.json}),
        ),
        available: () => true,
        semantics: 'event_published_only',
        execute: (args, requestId) async {
          final result = eventBus.publish(
            entry.key,
            args['data'],
            sourcePluginId: sourceId,
          );
          return {
            'status': 'published',
            'result': {
              'topic': entry.key,
              'enqueued_deliveries': result.enqueuedDeliveries,
              'dropped_deliveries': result.droppedDeliveries,
              'actuation_confirmed': false,
            },
          };
        },
      );
    }
    for (final command in configuration.pluginCommands) {
      _commands[command.name] = _Command(
        name: command.name,
        description: command.description,
        parameters: command.parameters,
        available: () => isPluginLoaded(command.pluginId),
        semantics: 'plugin_acknowledgement',
        execute: (args, requestId) => _executePlugin(command, args, requestId),
      );
    }
  }

  Future<Map<String, Object?>> _executePlugin(
    AssistantPluginCommand command,
    Map<String, Object?> arguments,
    String requestId,
  ) async {
    if (!isPluginLoaded(command.pluginId)) {
      throw const _BridgeError(
        503,
        'unavailable',
        'Target plugin is not loaded.',
      );
    }
    final result = Completer<Map<String, Object?>>();
    final subscription = eventBus.subscribe(
      ownerId: sourceId,
      topic: command.resultTopic,
      handler: (event) {
        final data = event.data;
        if (result.isCompleted ||
            event.sourcePluginId != command.pluginId ||
            !isPluginLoaded(command.pluginId) ||
            data is! Map) {
          return;
        }
        if (data['request_id'] != requestId ||
            data['command'] != command.name) {
          return;
        }
        if (data['status'] != 'succeeded' && data['status'] != 'failed') return;
        result.complete({
          'status': data['status'],
          'result': data['result'],
          if (data['status'] == 'failed')
            'error': {
              'code': 'plugin_failed',
              'message': 'The target plugin reported failure.',
            },
        });
      },
    );
    _subscriptions.add(subscription);
    try {
      final remaining = _expiresAt!.difference(_now());
      final timeout = remaining < command.timeout ? remaining : command.timeout;
      if (timeout <= Duration.zero) {
        throw const _BridgeError(
          409,
          'session_expired',
          'Wake session expired.',
        );
      }
      final published = eventBus.publish(command.requestTopic, {
        'request_id': requestId,
        'command': command.name,
        'arguments': arguments,
        'source': sourceId,
        'expires_at': _now().add(timeout).toUtc().toIso8601String(),
      }, sourcePluginId: sourceId);
      if (published.enqueuedDeliveries == 0) {
        return {
          'status': 'failed',
          'error': {
            'code': 'no_handler',
            'message': 'No plugin accepted the command event.',
          },
        };
      }
      return await result.future.timeout(
        timeout,
        onTimeout: () => {
          'status': 'unknown',
          'error': {
            'code': 'ack_timeout',
            'message': 'No matching plugin acknowledgement; outcome is unknown. Do not retry automatically.',
          },
        },
      );
    } finally {
      _subscriptions.remove(subscription);
      await subscription.cancel();
    }
  }

  Future<void> _handle(HttpRequest request) async {
    _activeRequests++;
    try {
      if (_closed) {
        throw const _BridgeError(
          503,
          'closing',
          'Assistant bridge is closing.',
        );
      }
      if (_activeRequests > 8) {
        throw const _BridgeError(429, 'busy', 'Too many requests.');
      }
      if (!_tokenMatches(
        request.headers.value(HttpHeaders.authorizationHeader),
      )) {
        throw const _BridgeError(
          401,
          'unauthorized',
          'Bearer authentication required.',
        );
      }
      // Browser origins cannot use this authenticated local service.
      if (request.headers.value('origin') != null) {
        throw const _BridgeError(
          403,
          'origin_forbidden',
          'Browser-origin requests are not accepted.',
        );
      }
      final response = await _route(request);
      await _respond(request, 200, response);
    } on _BridgeError catch (error) {
      await _respond(request, error.status, {
        'error': {'code': error.code, 'message': error.message},
      });
    } on FormatException catch (error) {
      await _respond(request, 400, {
        'error': {'code': 'invalid_request', 'message': error.message},
      });
    } on TimeoutException {
      await _respond(request, 408, {
        'error': {'code': 'request_timeout', 'message': 'Request timed out.'},
      });
    } on Object {
      await _respond(request, 500, {
        'error': {
          'code': 'internal_error',
          'message': 'Assistant bridge operation failed.',
        },
      });
    } finally {
      _activeRequests--;
    }
  }

  Future<Map<String, Object?>> _route(HttpRequest request) async {
    final path = request.uri.path;
    final method = request.method;
    if (method == 'GET' && path == '/v1/capabilities') {
      return {
        'protocol_version': 1,
        'source_id': sourceId,
        'commands': _commands.values
            .map((command) => command.describe())
            .toList(),
        'readable_keys': _readableKeys(),
        'event_topics': configuration.eventTopics,
        'request_id_format': '<server_session_id>:<unique_request_suffix>',
      };
    }
    if (method == 'GET' && path == '/v1/state') {
      final requested = _queryList(request.uri.queryParameters['keys']);
      final allowed = _readableKeys().toSet();
      if (requested.any((key) => !allowed.contains(key))) {
        throw const _BridgeError(
          403,
          'key_forbidden',
          'A requested data key is not readable.',
        );
      }
      final keys = requested.isEmpty ? allowed : requested;
      return {
        'values': {
          for (final key in keys)
            if (_audioKeys.contains(key))
              key: {
                'value': switch (key) {
                  'audio.volume' => audio.current.masterVolume,
                  'audio.muted' => audio.current.muted,
                  _ => audio.current.backendAvailable,
                },
                'timestamp': _now().toUtc().toIso8601String(),
                'sequence': 0,
                'source_id': 'argo.audio',
              }
            else if (vehicleDataBus.valueFor(key) case final point?)
              key: {
                'value': point.value,
                'timestamp': point.timestamp.toIso8601String(),
                'sequence': point.sequence,
                'source_id': point.sourcePluginId,
              },
        },
        'audio': _audioState(allowed: allowed),
      };
    }
    if (method == 'GET' && path == '/v1/events') {
      final topics = _queryList(request.uri.queryParameters['topics']);
      if (topics.any((topic) => !configuration.eventTopics.contains(topic))) {
        throw const _BridgeError(
          403,
          'topic_forbidden',
          'A requested topic is not observable.',
        );
      }
      final after = int.tryParse(request.uri.queryParameters['after'] ?? '0');
      if (after == null || after < 0) {
        throw const FormatException('after must be a nonnegative integer.');
      }
      return {
        'events': _events
            .where(
              (event) =>
                  (event['sequence'] as int) > after &&
                  (topics.isEmpty || topics.contains(event['topic'])),
            )
            .toList(),
        'cursor': _eventSequence,
        'truncated':
            _events.isNotEmpty &&
            after < (_events.first['sequence'] as int) - 1,
      };
    }
    if (method == 'DELETE' && path == '/v1/session') {
      if (request.uri.queryParameters['session_id'] != _sessionId) {
        throw const _BridgeError(409, 'invalid_session', 'Unknown session.');
      }
      _expiresAt = _now();
      _sessionTimer?.cancel();
      await _setFocus(false);
      return {'status': 'closed'};
    }
    if (method != 'POST') {
      throw const _BridgeError(404, 'not_found', 'Unknown bridge endpoint.');
    }
    final body = await _readBody(request);
    if (path == '/v1/session') {
      _only(body, {'wake_phrase', 'ttl_ms', 'session_id'});
      final wakePhrase = body['wake_phrase'];
      if (wakePhrase is! String ||
          wakePhrase.isEmpty ||
          wakePhrase.length > 64) {
        throw const FormatException('wake_phrase must be a short string.');
      }
      final ttl = body['ttl_ms'] ?? 30000;
      if (ttl is! int || ttl < 1 || ttl > 30000) {
        throw const FormatException('ttl_ms must be between 1 and 30000.');
      }
      _sessionTimer?.cancel();
      _expiresAt = _now();
      await _setFocus(false);
      _sessionId = base64Url
          .encode(List.generate(24, (_) => _random.nextInt(256)))
          .replaceAll('=', '');
      _expiresAt = _now().add(Duration(milliseconds: ttl));
      _sessionTimer = Timer(Duration(milliseconds: ttl), () {
        unawaited(_setFocus(false));
      });
      return {
        'session_id': _sessionId,
        'expires_at': _expiresAt!.toUtc().toIso8601String(),
      };
    }
    if (path == '/v1/focus' || path == '/v1/audio/focus') {
      _only(body, {'session_id', 'active'});
      final active = body['active'];
      if (active is! bool) {
        throw const FormatException('active must be boolean.');
      }
      if (active) {
        _requireSession(body['session_id']);
      } else if (body['session_id'] != _sessionId) {
        throw const _BridgeError(409, 'invalid_session', 'Unknown session.');
      }
      await _setFocus(active, sessionId: body['session_id']);
      return {
        'active': _focus != null,
        'ducking_supported': audio.current.capabilities.perSourceRouting,
      };
    }
    if (path == '/v1/execute') {
      _only(body, {'session_id', 'request_id', 'command', 'arguments'});
      final requestId = body['request_id'];
      final sessionId = body['session_id'];
      if (requestId is! String ||
          requestId.length > 160 ||
          sessionId is! String ||
          !requestId.startsWith('$sessionId:') ||
          !RegExp(r'^[A-Za-z0-9_:-]+$').hasMatch(requestId) ||
          requestId.length < sessionId.length + 9) {
        throw const FormatException(
          'request_id must be <server_session_id>:<unique suffix of at least 8 characters>.',
        );
      }
      final fingerprint = jsonEncode(_canonical(body));
      if (_requests[requestId] case final previous?) {
        if (previous.fingerprint != fingerprint) {
          throw const _BridgeError(
            409,
            'request_conflict',
            'Request ID was already used with different content.',
          );
        }
        return previous.result;
      }
      _requireSession(sessionId);
      final command = _commands[body['command']];
      if (command == null) {
        throw const _BridgeError(
          404,
          'unknown_command',
          'The command is not declared by this host.',
        );
      }
      final arguments = body['arguments'];
      if (arguments is! Map<String, Object?>) {
        throw const FormatException('arguments must be an object.');
      }
      command.parameters.validate(arguments);
      if (!command.available()) {
        throw const _BridgeError(
          503,
          'unavailable',
          'Command is currently unavailable.',
        );
      }
      final completer = Completer<Map<String, Object?>>();
      _requests[requestId] = _Execution(fingerprint, completer.future);
      if (_requests.length > 1024) {
        // An active session may never evict its own idempotency entries.
        final removable = _requests.keys
            .where((key) => !key.startsWith('$_sessionId:'))
            .firstOrNull;
        if (removable == null) {
          final rejected = {
            'request_id': requestId,
            'status': 'failed',
            'error': {
              'code': 'session_limit',
              'message': 'Session command limit reached.',
            },
          };
          completer.complete(rejected);
          _expiresAt = _now();
          return rejected;
        }
        _requests.remove(removable);
      }
      try {
        completer.complete({
          'request_id': requestId,
          ...await command.execute(arguments, requestId),
        });
      } on Object {
        // Preserve even unknown outcomes: a retry must never repeat side effects.
        completer.complete({
          'request_id': requestId,
          'status': 'unknown',
          'error': {
            'code': 'execution_failed',
            'message': 'Execution did not return a confirmed result. Do not retry automatically.',
          },
        });
      }
      return completer.future;
    }
    throw const _BridgeError(404, 'not_found', 'Unknown bridge endpoint.');
  }

  List<String> _readableKeys() =>
      (configuration.readableKeys ??
              ({..._audioKeys, ...vehicleDataBus.latest.keys}.toList()..sort()))
          .take(128)
          .toList();
  Map<String, Object?> _audioState({Set<String>? allowed}) => {
    if (allowed == null || allowed.contains('audio.volume'))
      'volume': audio.current.masterVolume,
    if (allowed == null || allowed.contains('audio.muted'))
      'muted': audio.current.muted,
    if (allowed == null || allowed.contains('audio.available'))
      'available': audio.current.backendAvailable,
  };

  void _requireSession(Object? id) {
    if (id is! String || id != _sessionId) {
      throw const _BridgeError(409, 'invalid_session', 'Unknown wake session.');
    }
    if (_expiresAt == null || !_now().isBefore(_expiresAt!)) {
      throw const _BridgeError(409, 'session_expired', 'Wake session expired.');
    }
  }

  Future<void> _setFocus(bool active, {Object? sessionId}) {
    final operation = _focusTail.then((_) async {
      if (active && !_closed && _focus == null) {
        _requireSession(sessionId);
        await audio.setSourceActive(sourceId, true);
        try {
          _focus = await audio.requestFocus(sourceId);
        } on Object {
          await audio.setSourceActive(sourceId, false);
          rethrow;
        }
      } else if (!active || _closed) {
        final focus = _focus;
        _focus = null;
        await focus?.release();
        await audio.setSourceActive(sourceId, false);
      }
    });
    _focusTail = operation.catchError((Object _) {});
    return operation;
  }

  bool _tokenMatches(String? header) {
    final expected = 'Bearer ${configuration.token}';
    if (header == null || header.length != expected.length) return false;
    var difference = 0;
    for (var i = 0; i < expected.length; i++) {
      difference |= expected.codeUnitAt(i) ^ header.codeUnitAt(i);
    }
    return difference == 0;
  }

  Future<Map<String, Object?>> _readBody(HttpRequest request) async {
    if (request.headers.contentType?.mimeType != 'application/json') {
      throw const _BridgeError(
        415,
        'content_type',
        'application/json is required.',
      );
    }
    final bytes = <int>[];
    var received = 0;
    final elapsed = Stopwatch()..start();
    await for (final chunk in request.timeout(const Duration(seconds: 3))) {
      received += chunk.length;
      // Drain a normal oversized body before responding: cancelling Dart's
      // request stream also closes its socket. Memory remains bounded.
      if (received <= 16384) bytes.addAll(chunk);
      if (elapsed.elapsed > const Duration(seconds: 3) || received > 1048576) {
        throw TimeoutException(
          'Request body did not finish within its limits.',
        );
      }
    }
    if (received > 16384) {
      throw const _BridgeError(
        413,
        'body_too_large',
        'Request body exceeds 16 KiB.',
      );
    }
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, Object?>) {
      throw const FormatException('JSON object required.');
    }
    return value;
  }

  static List<String> _queryList(String? value) {
    if (value == null || value.isEmpty) return [];
    if (value.length > 4096) throw const FormatException('Query is too long.');
    final items = value.split(',');
    if (items.length > 128 || items.any((item) => item.isEmpty)) {
      throw const FormatException('Invalid query list.');
    }
    return items;
  }

  static void _only(Map<String, Object?> value, Set<String> keys) {
    if (value.keys.any((key) => !keys.contains(key))) {
      throw const FormatException('Unknown request property.');
    }
  }

  static Object? _canonical(Object? value) {
    if (value is Map<String, Object?>) {
      return {
        for (final key in value.keys.toList()..sort())
          key: _canonical(value[key]),
      };
    }
    if (value is List) return value.map(_canonical).toList();
    return value;
  }

  static Future<void> _respond(
    HttpRequest request,
    int status,
    Map<String, Object?> value,
  ) async {
    try {
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      request.response.write(jsonEncode(value));
      await request.response.close();
    } on Object {
      // Client may disconnect after an action. Its recorded result is retained.
    }
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closed = true;
    _sessionTimer?.cancel();
    _expiresAt = _now();
    Object? firstError;
    StackTrace? firstStack;
    Future<void> cleanup(Future<void> Function() operation) async {
      try {
        await operation();
      } on Object catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }

    await cleanup(() async {
      await _server?.close(force: true);
    });
    await cleanup(() async {
      await _httpSubscription?.cancel();
    });
    await cleanup(() async {
      await Future.wait(_pendingHttp.toList());
    });
    for (final subscription in _subscriptions.toList()) {
      await cleanup(subscription.cancel);
    }
    _subscriptions.clear();
    if (_sourceRegistered) {
      await cleanup(() => _setFocus(false));
      await cleanup(() => audio.unregisterSource(sourceId));
      _sourceRegistered = false;
    }
    if (firstError case final error?) {
      Error.throwWithStackTrace(error, firstStack!);
    }
  }
}

final class _BridgeError implements Exception {
  const _BridgeError(this.status, this.code, this.message);
  final int status;
  final String code;
  final String message;
}

final class _Execution {
  const _Execution(this.fingerprint, this.result);
  final String fingerprint;
  final Future<Map<String, Object?>> result;
}

final class _Command {
  const _Command({
    required this.name,
    required this.description,
    required this.parameters,
    required this.available,
    required this.semantics,
    required this.execute,
  });
  final String name;
  final String description;
  final AssistantSchema parameters;
  final bool Function() available;
  final String semantics;
  final Future<Map<String, Object?>> Function(Map<String, Object?>, String)
  execute;
  Map<String, Object?> describe() => {
    'name': name,
    'description': description,
    'parameters': parameters.json,
    'requires_session': true,
    'available': available(),
    'result_semantics': semantics,
  };
}
