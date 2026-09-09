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
import 'package:flutter_test/flutter_test.dart';
import 'package:veloce_lua_core/veloce_lua_core.dart';

void main() {
  late _Fixture fixture;
  setUp(() async {
    fixture = await _Fixture.create();
  });
  tearDown(() async {
    await fixture.close();
  });

  test(
    'authentication and browser-origin rejection happen before reads',
    () async {
      expect(
        (await fixture.call(
          'GET',
          '/v1/capabilities',
          authenticated: false,
        )).status,
        401,
      );
      expect(
        (await fixture.call(
          'GET',
          '/v1/state',
          origin: 'https://example.org',
        )).status,
        403,
      );
      final capabilities = await fixture.call('GET', '/v1/capabilities');
      expect(capabilities.status, 200);
      expect(capabilities.body['protocol_version'], 1);
      expect(
        (capabilities.body['commands'] as List).map((c) => c['name']),
        contains('audio.set_volume'),
      );
    },
  );

  test(
    'reads live bus with provenance; undeclared keys cannot be read',
    () async {
      fixture.vehicle.publish(
        'vehicle.speed',
        42,
        sourcePluginId: 'vehicle.demo',
      );
      final state = await fixture.call('GET', '/v1/state?keys=vehicle.speed');
      final value = (state.body['values'] as Map)['vehicle.speed'] as Map;
      expect(value['value'], 42);
      expect(value['source_id'], 'vehicle.demo');
      expect(
        (await fixture.call('GET', '/v1/state?keys=secret.key')).status,
        403,
      );
    },
  );

  test('virtual audio values cannot be spoofed by bus writers', () async {
    fixture.vehicle.publish(
      'audio.volume',
      999,
      sourcePluginId: 'untrusted.plugin',
    );
    final state = await fixture.call(
      'GET',
      '/v1/state?keys=audio.volume,audio.muted',
    );
    final values = state.body['values'] as Map;
    expect(values['audio.volume']['value'], fixture.audio.current.masterVolume);
    expect(values['audio.volume']['source_id'], 'argo.audio');
    expect(values['audio.muted']['value'], false);
  });

  test('explicit read grants restrict virtual values and the audio convenience object', () async {
    await fixture.close();
    fixture = await _Fixture.create(readableKeys: ['vehicle.speed']);
    final capabilities = await fixture.call('GET', '/v1/capabilities');
    expect(capabilities.body['readable_keys'], ['vehicle.speed']);
    expect((await fixture.call('GET', '/v1/state')).body['audio'], isEmpty);
    expect(
      (await fixture.call('GET', '/v1/state?keys=audio.volume')).status,
      403,
    );
  });

  test(
    'strict arguments, undeclared command and missing session cannot actuate',
    () async {
      final initial = fixture.audio.current.masterVolume;
      expect(
        (await fixture.execute('audio.set_volume', {
          'value': 0.8,
        }, session: 'missing')).status,
        409,
      );
      final session = await fixture.session();
      for (final args in [
        {'value': 1.1},
        {'value': '0.8'},
        {'value': 0.8, 'extra': true},
      ]) {
        expect(
          (await fixture.execute(
            'audio.set_volume',
            args,
            session: session,
          )).status,
          400,
        );
      }
      expect(
        (await fixture.execute(
          'vehicle.start_engine',
          {},
          session: session,
        )).status,
        404,
      );
      expect(fixture.audio.current.masterVolume, initial);
    },
  );

  test(
    'duplicate requests return same result and volume changes once',
    () async {
      final session = await fixture.session();
      final before = fixture.audio.current.masterVolume;
      final calls = await Future.wait([
        fixture.execute(
          'audio.volume_step',
          {'direction': 'up'},
          session: session,
          suffix: 'duplicate1',
        ),
        fixture.execute(
          'audio.volume_step',
          {'direction': 'up'},
          session: session,
          suffix: 'duplicate1',
        ),
      ]);
      expect(calls.first.body, calls.last.body);
      expect(calls.first.body['status'], 'succeeded');
      expect(
        fixture.audio.current.masterVolume,
        closeTo(before + 0.05, 0.0001),
      );
      final conflict = await fixture.execute(
        'audio.volume_step',
        {'direction': 'down'},
        session: session,
        suffix: 'duplicate1',
      );
      expect(conflict.status, 409);
      fixture.now = fixture.now.add(const Duration(seconds: 31));
      expect(
        (await fixture.execute(
          'audio.volume_step',
          {'direction': 'up'},
          session: session,
          suffix: 'duplicate1',
        )).body,
        calls.first.body,
      );
      expect(
        (await fixture.execute(
          'audio.volume_step',
          {'direction': 'up'},
          session: session,
          suffix: 'newrequest',
        )).status,
        409,
      );
    },
  );

  test(
    'server session replaces caller ID and old IDs cannot execute again',
    () async {
      final first = await fixture.session();
      expect(first, isNot('client-wake-id'));
      final second = await fixture.session();
      expect(second, isNot(first));
      expect(
        (await fixture.execute('audio.set_muted', {
          'muted': true,
        }, session: first)).status,
        409,
      );
      final mismatch = await fixture.call(
        'POST',
        '/v1/execute',
        body: {
          'session_id': second,
          'request_id': '$first:oldrequest',
          'command': 'audio.set_muted',
          'arguments': {'muted': true},
        },
      );
      expect(mismatch.status, 400);
      expect(fixture.audio.current.muted, false);
    },
  );

  test(
    'disabled audio backend is unavailable and never reports success',
    () async {
      await fixture.close();
      fixture = await _Fixture.create(available: false);
      final capabilities = await fixture.call('GET', '/v1/capabilities');
      expect(
        (capabilities.body['commands'] as List).every(
          (c) => c['available'] == false,
        ),
        true,
      );
      final session = await fixture.session();
      final result = await fixture.execute('audio.set_muted', {
        'muted': true,
      }, session: session);
      expect(result.status, 503);
      expect(fixture.audio.current.muted, false);
    },
  );

  test(
    'plugin acknowledgement requires target identity and correlation',
    () async {
      await fixture.close();
      fixture = await _Fixture.create(plugin: true);
      var executions = 0;
      fixture.events.subscribe(
        ownerId: 'plugin.demo',
        topic: 'demo.command',
        handler: (event) async {
          executions++;
          expect(event.sourcePluginId, 'argo.assistant');
          final data = event.data as Map;
          final ack = {
            'request_id': data['request_id'],
            'command': data['command'],
            'status': 'succeeded',
            'result': {'applied': true},
          };
          fixture.events.publish('demo.result', {
            ...ack,
            'result': {'spoof': true},
          }, sourcePluginId: 'wrong.plugin');
          fixture.events.publish('demo.result', {
            ...ack,
            'request_id': 'wrong',
          }, sourcePluginId: 'plugin.demo');
          fixture.events.publish(
            'demo.result',
            ack,
            sourcePluginId: 'plugin.demo',
          );
        },
      );
      final session = await fixture.session();
      final result = await fixture.execute(
        'demo.set_level',
        {'level': 2},
        session: session,
        suffix: 'pluginonce',
      );
      expect(result.body['status'], 'succeeded');
      expect(result.body['result'], {'applied': true});
      expect(
        (await fixture.execute(
          'demo.set_level',
          {'level': 2},
          session: session,
          suffix: 'pluginonce',
        )).body,
        result.body,
      );
      expect(executions, 1);
    },
  );

  test(
    'plugin enqueue without acknowledgement remains unknown and is not retried',
    () async {
      await fixture.close();
      fixture = await _Fixture.create(plugin: true);
      var executions = 0;
      fixture.events.subscribe(
        ownerId: 'plugin.demo',
        topic: 'demo.command',
        handler: (_) {
          executions++;
        },
      );
      final session = await fixture.session();
      final result = await fixture.execute(
        'demo.set_level',
        {'level': 2},
        session: session,
        suffix: 'timeoutone',
      );
      expect(result.body['status'], 'unknown');
      expect((result.body['error'] as Map)['code'], 'ack_timeout');
      await fixture.execute(
        'demo.set_level',
        {'level': 2},
        session: session,
        suffix: 'timeoutone',
      );
      expect(executions, 1);
    },
  );

  test(
    'unloaded plugin and plugin without handler cannot report success',
    () async {
      await fixture.close();
      fixture = await _Fixture.create(plugin: true);
      final session = await fixture.session();
      expect(
        (await fixture.execute('demo.set_level', {
          'level': 2,
        }, session: session)).body['status'],
        'failed',
      );
      fixture.pluginLoaded = false;
      expect(
        (await fixture.execute('demo.set_level', {
          'level': 2,
        }, session: session)).status,
        503,
      );
    },
  );

  test('explicit data and event grants preserve assistant attribution and publication semantics', () async {
    await fixture.close();
    fixture = await _Fixture.create(busGrants: true);
    final seen = <PluginEvent>[];
    fixture.events.subscribe(
      ownerId: 'observer',
      topic: 'assistant.note',
      handler: seen.add,
    );
    final session = await fixture.session();
    final data = await fixture.execute('data.write.assistant.mode', {
      'value': 'quiet',
    }, session: session);
    expect(data.body['status'], 'published');
    expect((data.body['result'] as Map)['actuation_confirmed'], false);
    expect(
      fixture.vehicle.valueFor('assistant.mode')!.sourcePluginId,
      'argo.assistant',
    );
    expect(
      (await fixture.execute('event.publish.assistant.note', {
        'data': 'hello',
      }, session: session)).body['status'],
      'published',
    );
    await fixture.events.flush();
    expect(seen.single.sourcePluginId, 'argo.assistant');
    final events = await fixture.call(
      'GET',
      '/v1/events?after=0&topics=assistant.note',
    );
    expect((events.body['events'] as List).single['data'], 'hello');
  });

  test('focus lease is released on session end and shutdown', () async {
    final session = await fixture.session();
    expect(
      (await fixture.call(
        'POST',
        '/v1/focus',
        body: {'session_id': session, 'active': true},
      )).body['active'],
      true,
    );
    expect(fixture.audio.current.focusSources, contains('argo.assistant'));
    expect(fixture.audio.current.activeSources, contains('argo.assistant'));
    expect(fixture.audio.current.effectiveSourceGains['argo.assistant'], 1);
    await fixture.call('DELETE', '/v1/session?session_id=$session');
    expect(fixture.audio.current.focusSources, isEmpty);
    expect(
      (await fixture.execute('audio.set_muted', {
        'muted': true,
      }, session: session)).status,
      409,
    );
    final next = await fixture.session();
    await fixture.call(
      'POST',
      '/v1/focus',
      body: {'session_id': next, 'active': true},
    );
    await fixture.bridge.close();
    expect(fixture.audio.current.focusSources, isEmpty);
  });

  test(
    'body bound and maximum session duration reject malformed input',
    () async {
      expect(
        (await fixture.call(
          'POST',
          '/v1/session',
          body: {'wake_phrase': 'Hey Argo', 'ttl_ms': 30001},
        )).status,
        400,
      );
      expect(
        (await fixture.call(
          'POST',
          '/v1/session',
          body: {'wake_phrase': 'x' * 17000},
        )).status,
        413,
      );
    },
  );
}

final class _Fixture {
  static const token = 'test-token-abcdefghijklmnopqrstuvwxyz0123456789';
  final events = PluginEventBus();
  final vehicle = VehicleDataBus();
  final client = HttpClient();
  late SettingsService settings;
  late DefaultAudioService audio;
  late AssistantBridge bridge;
  var now = DateTime.utc(2026, 9, 9);
  var pluginLoaded = true;
  var _next = 0;
  var _closed = false;

  static Future<_Fixture> create({
    bool available = true,
    bool plugin = false,
    bool busGrants = false,
    List<String>? readableKeys = const [
      'vehicle.speed',
      'assistant.mode',
      'audio.volume',
      'audio.muted',
      'audio.available',
    ],
  }) async {
    final fixture = _Fixture();
    fixture.settings = await SettingsService.load(
      schema: AppSettingKeys.createSchema(),
      store: _MemoryStore(),
    );
    fixture.audio = await DefaultAudioService.start(
      backend: InMemoryAudioBackend(available: available),
      settings: fixture.settings,
      diagnostics: DiagnosticsService(),
    );
    fixture.bridge = await AssistantBridge.start(
      configuration: AssistantBridgeConfiguration(
        token: token,
        port: 0,
        readableKeys: readableKeys,
        eventTopics: busGrants ? ['assistant.note'] : [],
        writableData: busGrants
            ? {
                'assistant.mode': AssistantSchema({
                  'type': 'string',
                  'enum': ['quiet', 'normal'],
                }),
              }
            : {},
        publishEvents: busGrants
            ? {
                'assistant.note': AssistantSchema({
                  'type': 'string',
                  'maxLength': 64,
                }),
              }
            : {},
        pluginCommands: plugin
            ? [
                AssistantPluginCommand(
                  name: 'demo.set_level',
                  description: 'Set demo level.',
                  pluginId: 'plugin.demo',
                  requestTopic: 'demo.command',
                  resultTopic: 'demo.result',
                  parameters: AssistantSchema(
                    assistantObjectSchema({
                      'level': {'type': 'integer', 'minimum': 0, 'maximum': 3},
                    }),
                  ),
                  timeout: const Duration(milliseconds: 80),
                ),
              ]
            : [],
      ),
      eventBus: fixture.events,
      vehicleDataBus: fixture.vehicle,
      audio: fixture.audio,
      isPluginLoaded: (_) => fixture.pluginLoaded,
      now: () => fixture.now,
    );
    return fixture;
  }

  Future<_Response> call(
    String method,
    String path, {
    Map<String, Object?>? body,
    bool authenticated = true,
    String? origin,
  }) async {
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${bridge.port}$path'),
    );
    if (authenticated) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    if (origin != null) request.headers.set('origin', origin);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    return _Response(
      response.statusCode,
      jsonDecode(await utf8.decoder.bind(response).join())
          as Map<String, Object?>,
    );
  }

  Future<String> session() async =>
      (await call(
            'POST',
            '/v1/session',
            body: {
              'session_id': 'client-wake-id',
              'wake_phrase': 'Hey Argo',
              'ttl_ms': 30000,
            },
          )).body['session_id']
          as String;
  Future<_Response> execute(
    String command,
    Map<String, Object?> arguments, {
    required String session,
    String? suffix,
  }) => call(
    'POST',
    '/v1/execute',
    body: {
      'session_id': session,
      'request_id': '$session:${suffix ?? 'request_${_next++}'}',
      'command': command,
      'arguments': arguments,
    },
  );
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    client.close(force: true);
    await bridge.close();
    await audio.close();
    await settings.close();
    await events.close();
    await vehicle.close();
  }
}

final class _Response {
  const _Response(this.status, this.body);
  final int status;
  final Map<String, Object?> body;
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
