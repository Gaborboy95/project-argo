import 'dart:convert';
import 'dart:io';

import 'package:veloce_lua_core/veloce_lua_core.dart';

import 'assistant_schema.dart';

final class AssistantPluginCommand {
  AssistantPluginCommand({
    required this.name,
    required this.description,
    required this.pluginId,
    required this.requestTopic,
    required this.resultTopic,
    required this.parameters,
    this.timeout = const Duration(seconds: 5),
  }) {
    if (!RegExp(r'^[a-z][a-z0-9_.]{1,95}$').hasMatch(name) ||
        name.startsWith('audio.') ||
        name.startsWith('data.') ||
        name.startsWith('event.') ||
        pluginId.trim().isEmpty ||
        description.length > 256 ||
        parameters.json['type'] != 'object' ||
        timeout.inMilliseconds < 1 ||
        timeout.inMilliseconds > 10000) {
      throw const FormatException('Invalid assistant plugin command.');
    }
    PluginEventBus.validateTopic(requestTopic);
    PluginEventBus.validateTopic(resultTopic);
    if (requestTopic == resultTopic) {
      throw const FormatException('Request and result topics must differ.');
    }
  }
  final String name;
  final String description;
  final String pluginId;
  final String requestTopic;
  final String resultTopic;
  final AssistantSchema parameters;
  final Duration timeout;
}

/// Host-owned allowlists. Plugins cannot grant themselves assistant authority.
final class AssistantBridgeConfiguration {
  AssistantBridgeConfiguration({
    required this.token,
    this.port = 8791,
    this.readableKeys,
    this.eventTopics = const [],
    this.writableData = const {},
    this.publishEvents = const {},
    this.pluginCommands = const [],
  }) {
    if (!RegExp(r'^[A-Za-z0-9_-]{32,256}$').hasMatch(token)) {
      throw const FormatException(
        'Assistant token must be 32–256 URL-safe characters.',
      );
    }
    if (port < 0 || port > 65535) {
      throw const FormatException('Invalid assistant port.');
    }
    for (final key in [...?readableKeys, ...writableData.keys]) {
      VehicleDataBus.validateKey(key);
    }
    for (final topic in [...eventTopics, ...publishEvents.keys]) {
      PluginEventBus.validateTopic(topic);
    }
    if (pluginCommands.map((c) => c.name).toSet().length !=
            pluginCommands.length ||
        pluginCommands.length > 64 ||
        eventTopics.length > 64 ||
        writableData.length > 64 ||
        publishEvents.length > 64 ||
        (readableKeys?.length ?? 0) > 128) {
      throw const FormatException(
        'Duplicate commands or oversized assistant allowlist.',
      );
    }
  }

  final String token;
  final int port;
  final List<String>? readableKeys;
  final List<String> eventTopics;
  final Map<String, AssistantSchema> writableData;
  final Map<String, AssistantSchema> publishEvents;
  final List<AssistantPluginCommand> pluginCommands;

  static Future<AssistantBridgeConfiguration?> fromEnvironment(
    Map<String, String> environment,
  ) async {
    final enabled = environment['ARGO_ASSISTANT_BRIDGE'];
    if (enabled == null || enabled == '0') return null;
    if (enabled != '1') {
      throw const FormatException('ARGO_ASSISTANT_BRIDGE must be 0 or 1.');
    }
    final tokenPath = environment['ARGO_ASSISTANT_TOKEN_FILE'];
    if (tokenPath == null || tokenPath.trim().isEmpty) {
      throw const FormatException(
        'ARGO_ASSISTANT_TOKEN_FILE is required when the bridge is enabled.',
      );
    }
    final tokenFile = File(tokenPath);
    if (await tokenFile.length() > 512) {
      throw const FormatException('Invalid token file size.');
    }
    final token = (await tokenFile.readAsString()).trim();
    final configuredPort = environment['ARGO_ASSISTANT_PORT'];
    final port = configuredPort == null ? 8791 : int.parse(configuredPort);
    final path = environment['ARGO_ASSISTANT_CONFIG_FILE'];
    final Map<String, Object?> document;
    if (path == null) {
      document = {};
    } else {
      final file = File(path);
      if (await file.length() > 65536) {
        throw const FormatException('Assistant config exceeds 64 KiB.');
      }
      document = _object(jsonDecode(await file.readAsString()));
    }
    _only(document, {
      'readable_keys',
      'event_topics',
      'writable_data',
      'publish_events',
      'plugin_commands',
    });
    List<String> strings(String key) {
      final value = document[key] ?? const [];
      if (value is! List || value.any((item) => item is! String)) {
        throw FormatException('Invalid $key.');
      }
      return value.cast<String>();
    }

    Map<String, AssistantSchema> schemas(String field, String name) {
      final result = <String, AssistantSchema>{};
      final entries = document[field] ?? const [];
      if (entries is! List) throw FormatException('$field must be an array.');
      for (final entry in entries) {
        final item = _object(entry);
        _only(item, {name, 'schema'});
        final key = item[name];
        if (key is! String || result.containsKey(key)) {
          throw FormatException('Invalid $field key.');
        }
        result[key] = AssistantSchema(_object(item['schema']));
      }
      return result;
    }

    final commands = document['plugin_commands'] ?? const [];
    if (commands is! List) {
      throw const FormatException('plugin_commands must be an array.');
    }
    return AssistantBridgeConfiguration(
      token: token,
      port: port,
      readableKeys: document.containsKey('readable_keys')
          ? strings('readable_keys')
          : null,
      eventTopics: strings('event_topics'),
      writableData: schemas('writable_data', 'key'),
      publishEvents: schemas('publish_events', 'topic'),
      pluginCommands: commands.map((entry) {
        final item = _object(entry);
        _only(item, {
          'name',
          'description',
          'plugin_id',
          'request_topic',
          'result_topic',
          'parameters',
          'timeout_ms',
        });
        return AssistantPluginCommand(
          name: _string(item, 'name'),
          description: _string(item, 'description'),
          pluginId: _string(item, 'plugin_id'),
          requestTopic: _string(item, 'request_topic'),
          resultTopic: _string(item, 'result_topic'),
          parameters: AssistantSchema(_object(item['parameters'])),
          timeout: Duration(milliseconds: item['timeout_ms'] as int? ?? 5000),
        );
      }).toList(),
    );
  }

  static String _string(Map<String, Object?> item, String key) {
    final value = item[key];
    if (value is! String) throw FormatException('$key must be a string.');
    return value;
  }

  static Map<String, Object?> _object(Object? value) {
    if (value is! Map<String, Object?>) {
      throw const FormatException('Expected JSON object.');
    }
    return value;
  }

  static void _only(Map<String, Object?> item, Set<String> keys) {
    if (item.keys.any((key) => !keys.contains(key))) {
      throw const FormatException('Unknown assistant configuration property.');
    }
  }
}
