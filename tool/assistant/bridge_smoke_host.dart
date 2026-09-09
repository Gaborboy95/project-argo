// Runs the production HTTP bridge against in-memory Argo services, without
// loading Lua, native libraries, CAN, projection, or the Flutter UI.
// dart run tool/assistant/bridge_smoke_host.dart TOKEN_FILE [PORT]
// A zero/default port is selected by the OS. Send "quit" on stdin to stop.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:argo/core/audio/audio_service.dart';
import 'package:argo/core/audio/in_memory_audio_backend.dart';
import 'package:argo/core/diagnostics/diagnostics_service.dart';
import 'package:argo/core/settings/app_setting_keys.dart';
import 'package:argo/core/settings/settings_service.dart';
import 'package:argo/core/settings/settings_store.dart';
import 'package:argo/integrations/assistant/assistant_bridge.dart';
import 'package:argo/integrations/assistant/assistant_bridge_configuration.dart';
import 'package:argo/integrations/assistant/assistant_schema.dart';
import 'package:veloce_lua_core/veloce_lua_core.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty || arguments.length > 2) {
    stderr.writeln(
      'Usage: dart run tool/assistant/bridge_smoke_host.dart TOKEN_FILE [PORT]',
    );
    exitCode = 64;
    return;
  }
  final token = (await File(arguments.first).readAsString()).trim();
  final settings = await SettingsService.load(
    schema: AppSettingKeys.createSchema(),
    store: _MemoryStore(),
  );
  final audio = await DefaultAudioService.start(
    backend: InMemoryAudioBackend(),
    settings: settings,
    diagnostics: DiagnosticsService(),
  );
  final events = PluginEventBus();
  final vehicle = VehicleDataBus()
    ..publish('vehicle.speed', 0, sourcePluginId: 'argo.smoke');
  final bridge = await AssistantBridge.start(
    configuration: AssistantBridgeConfiguration(
      token: token,
      port: arguments.length == 2 ? int.parse(arguments[1]) : 0,
      eventTopics: ['assistant.note'],
      writableData: {
        'assistant.mode': AssistantSchema({
          'type': 'string',
          'enum': ['quiet', 'normal'],
        }),
      },
      publishEvents: {
        'assistant.note': AssistantSchema({'type': 'string', 'maxLength': 64}),
      },
      pluginCommands: [
        AssistantPluginCommand(
          name: 'demo.set_level',
          description: 'Set an in-memory demonstration level.',
          pluginId: 'demo.assistant',
          requestTopic: 'demo.assistant.request',
          resultTopic: 'demo.assistant.result',
          parameters: AssistantSchema(
            assistantObjectSchema({
              'level': {'type': 'integer', 'minimum': 0, 'maximum': 3},
            }),
          ),
        ),
      ],
    ),
    eventBus: events,
    vehicleDataBus: vehicle,
    audio: audio,
    isPluginLoaded: (id) => id == 'demo.assistant',
  );
  events.subscribe(
    ownerId: 'demo.assistant',
    topic: 'demo.assistant.request',
    handler: (event) {
      final data = event.data as Map;
      final arguments = data['arguments'] as Map;
      vehicle.publish(
        'demo.level',
        arguments['level'],
        sourcePluginId: 'demo.assistant',
      );
      events.publish('demo.assistant.result', {
        'request_id': data['request_id'],
        'command': data['command'],
        'status': 'succeeded',
        'result': {'level': arguments['level']},
      }, sourcePluginId: 'demo.assistant');
    },
  );
  stdout.writeln(
    jsonEncode({
      'url': 'http://127.0.0.1:${bridge.port}',
      'mode': 'in_memory_smoke',
    }),
  );
  final stop = Completer<void>();
  final input = stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        if (line.trim() == 'quit' && !stop.isCompleted) stop.complete();
      });
  // Keep the fixture available when its launcher closes stdin.
  final keepAlive = Timer.periodic(const Duration(seconds: 1), (_) {});
  try {
    await stop.future;
  } finally {
    keepAlive.cancel();
    await input.cancel();
    await bridge.close();
    await audio.close();
    await settings.close();
    await events.close();
    await vehicle.close();
  }
}

final class _MemoryStore implements SettingsStore {
  SettingsDocument document = SettingsDocument();
  @override
  Future<SettingsDocument> read() async => document;
  @override
  Future<void> write(SettingsDocument document) async {
    this.document = document;
  }
}
