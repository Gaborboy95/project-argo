import 'dart:convert';
import 'dart:io';

import 'package:argo/app/assistant_composition.dart';
import 'package:argo/core/diagnostics/diagnostics_service.dart';
import 'package:argo/core/lifecycle/app_lifecycle_coordinator.dart';
import 'package:argo/core/services/service_registry.dart';
import 'package:argo/integrations/assistant/assistant_bridge_configuration.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'disabled assistant does not require Veloce or audio services',
    () async {
      expect(
        await registerAssistantServices(
          services: ServiceRegistry(),
          lifecycle: AppLifecycleCoordinator(),
          diagnostics: DiagnosticsService(),
          environment: {},
        ),
        isNull,
      );
    },
  );
  test(
    'enabled bridge fails closed without token or on misspelled enable value',
    () async {
      for (final value in ['1', 'true']) {
        await expectLater(
          AssistantBridgeConfiguration.fromEnvironment({
            'ARGO_ASSISTANT_BRIDGE': value,
          }),
          throwsFormatException,
        );
      }
    },
  );
  test(
    'loads explicit host grants and rejects unknown schema keywords',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'argo-assistant-config-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final token = File('${directory.path}/token');
      await token.writeAsString('abcdefghijklmnopqrstuvwxyz0123456789-test');
      final config = File('${directory.path}/config.json');
      final environment = {
        'ARGO_ASSISTANT_BRIDGE': '1',
        'ARGO_ASSISTANT_TOKEN_FILE': token.path,
        'ARGO_ASSISTANT_CONFIG_FILE': config.path,
      };
      await config.writeAsString(
        jsonEncode({
          'readable_keys': ['vehicle.speed'],
          'writable_data': [
            {
              'key': 'assistant.mode',
              'schema': {
                'type': 'string',
                'enum': ['quiet'],
              },
            },
          ],
        }),
      );
      final loaded = await AssistantBridgeConfiguration.fromEnvironment(
        environment,
      );
      expect(loaded!.readableKeys, ['vehicle.speed']);
      expect(loaded.writableData.keys, ['assistant.mode']);
      await config.writeAsString(
        jsonEncode({
          'writable_data': [
            {
              'key': 'assistant.mode',
              'schema': {'type': 'string', 'pattern': 'anything'},
            },
          ],
        }),
      );
      await expectLater(
        AssistantBridgeConfiguration.fromEnvironment(environment),
        throwsFormatException,
      );
      await config.writeAsString('{"allow_all_writes":true}');
      await expectLater(
        AssistantBridgeConfiguration.fromEnvironment(environment),
        throwsFormatException,
      );
    },
  );
}
