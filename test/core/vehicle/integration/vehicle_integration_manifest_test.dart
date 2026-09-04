import 'dart:convert';
import 'dart:io';

import 'package:argo/core/vehicle/integration/vehicle_integration_manifest.dart';
import 'package:argo/core/vehicle/vehicle_capability.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const parser = VehicleIntegrationManifestParser();

  test('parses a valid external vehicle manifest', () {
    final profile = parser.parse({
      'schemaVersion': 1,
      'id': 'example-vehicle',
      'displayName': 'Example Vehicle',
      'capabilities': ['vehicle.telemetry', 'climate.control'],
    });

    expect(profile.id, 'example-vehicle');
    expect(profile.displayName, 'Example Vehicle');
    expect(profile.capabilities, {
      VehicleCapabilities.telemetry,
      VehicleCapabilities.climateControl,
    });
  });

  test('defaults omitted capabilities to empty', () {
    final profile = parser.parse({
      'schemaVersion': 1,
      'id': 'example-vehicle',
      'displayName': 'Example Vehicle',
    });

    expect(profile.capabilities, isEmpty);
  });

  test('rejects unsupported schema versions', () {
    expect(
      () => parser.parse({
        'schemaVersion': 2,
        'id': 'example-vehicle',
        'displayName': 'Example Vehicle',
      }),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('Unsupported vehicle integration schema version: 2'),
        ),
      ),
    );
  });

  test('reports malformed JSON with its manifest file', () async {
    final root = await Directory.systemTemp.createTemp('argo-manifest-test-');
    addTearDown(() => root.delete(recursive: true));
    final manifest = File.fromUri(root.uri.resolve('vehicle.json'));
    await manifest.writeAsString('{not json');

    await expectLater(
      parser.load(manifest),
      throwsA(
        isA<VehicleIntegrationManifestException>()
            .having((error) => error.filePath, 'filePath', manifest.path)
            .having(
              (error) => error.toString(),
              'message',
              allOf(contains('vehicle.json'), contains('FormatException')),
            ),
      ),
    );
  });

  test('rejects invalid vehicle and capability IDs', () {
    expect(
      () => parser.parse({
        'schemaVersion': 1,
        'id': 'Invalid Vehicle',
        'displayName': 'Invalid Vehicle',
      }),
      throwsFormatException,
    );
    expect(
      () => parser.parse({
        'schemaVersion': 1,
        'id': 'example-vehicle',
        'displayName': 'Example Vehicle',
        'capabilities': ['not namespaced'],
      }),
      throwsFormatException,
    );
  });

  test('rejects duplicate capability declarations clearly', () {
    expect(
      () => parser.parseString(
        jsonEncode({
          'schemaVersion': 1,
          'id': 'example-vehicle',
          'displayName': 'Example Vehicle',
          'capabilities': ['vehicle.telemetry', 'vehicle.telemetry'],
        }),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('Duplicate capability "vehicle.telemetry"'),
        ),
      ),
    );
  });
}
