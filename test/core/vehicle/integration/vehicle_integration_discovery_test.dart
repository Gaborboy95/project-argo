import 'dart:convert';
import 'dart:io';

import 'package:argo/core/vehicle/integration/vehicle_integration_discovery.dart';
import 'package:argo/core/vehicle/integration/vehicle_integration_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('discovers immediate external integrations', () async {
    final root = await Directory.systemTemp.createTemp('argo-vehicles-test-');
    addTearDown(() => root.delete(recursive: true));
    await _writeBundle(root, 'example-vehicle');

    final result = await const VehicleIntegrationDiscovery().discover(root);

    expect(result.failures, isEmpty);
    expect(result.bundles.single.profile.id, 'example-vehicle');
    expect(
      result.bundles.single.velocePluginDirectory.path,
      endsWith(
        '${Platform.pathSeparator}example-vehicle'
        '${Platform.pathSeparator}plugins',
      ),
    );
  });

  test('discovery order follows sorted child directory paths', () async {
    final root = await Directory.systemTemp.createTemp('argo-order-test-');
    addTearDown(() => root.delete(recursive: true));
    await _writeBundle(root, 'b-bundle', profileId: 'alpha');
    await _writeBundle(root, 'a-bundle', profileId: 'zeta');

    final result = await const VehicleIntegrationDiscovery().discover(root);

    expect(
      result.bundles.map((bundle) => bundle.profile.id),
      orderedEquals(['zeta', 'alpha']),
    );
  });

  test('rejects duplicate external profile IDs', () async {
    final root = await Directory.systemTemp.createTemp('argo-duplicate-test-');
    addTearDown(() => root.delete(recursive: true));
    await _writeBundle(root, 'first', profileId: 'duplicate');
    await _writeBundle(root, 'second', profileId: 'duplicate');

    await expectLater(
      const VehicleIntegrationDiscovery().discover(root),
      throwsA(
        isA<DuplicateVehicleIntegrationProfileException>().having(
          (error) => error.profileId,
          'profileId',
          'duplicate',
        ),
      ),
    );
  });

  test('retains unrelated malformed bundles as failures', () async {
    final root = await Directory.systemTemp.createTemp('argo-failure-test-');
    addTearDown(() => root.delete(recursive: true));
    await _writeBundle(root, 'valid');
    final broken = await _writeBundle(root, 'broken');
    await File.fromUri(broken.uri.resolve('vehicle.json')).writeAsString('{');

    final result = await const VehicleIntegrationDiscovery().discover(root);

    expect(result.bundles.single.profile.id, 'valid');
    expect(result.failures.single.bundleDirectory.uri, broken.uri);
    expect(
      result.failures.single.error,
      isA<VehicleIntegrationManifestException>(),
    );
  });

  test('integration root must be explicit and absolute', () {
    expect(vehicleIntegrationsDirectoryFromEnvironment(const {}), isNull);
    expect(
      vehicleIntegrationsDirectoryFromEnvironment(const {
        'ARGO_VEHICLE_INTEGRATIONS_DIR': '',
      }),
      isNull,
    );
    expect(
      () => vehicleIntegrationsDirectoryFromEnvironment(const {
        'ARGO_VEHICLE_INTEGRATIONS_DIR': 'relative/vehicles',
      }),
      throwsArgumentError,
    );
  });

  test('repository synthetic example integration is discoverable', () async {
    final root = Directory('tool/vehicle_integrations').absolute;

    final result = await const VehicleIntegrationDiscovery().discover(root);

    expect(result.failures, isEmpty);
    expect(result.bundles.single.profile.id, 'example-vehicle');
    expect(result.bundles.single.profile.capabilities.map((item) => item.id), [
      'vehicle.telemetry',
    ]);
  });
}

Future<Directory> _writeBundle(
  Directory root,
  String directoryName, {
  String? profileId,
}) async {
  final bundle = Directory.fromUri(root.uri.resolve('$directoryName/'));
  await Directory.fromUri(bundle.uri.resolve('plugins/'))
      .create(recursive: true);
  await File.fromUri(bundle.uri.resolve('vehicle.json')).writeAsString(
    jsonEncode({
      'schemaVersion': 1,
      'id': profileId ?? directoryName,
      'displayName': 'Test Vehicle',
      'capabilities': ['vehicle.telemetry'],
    }),
  );
  return bundle.absolute;
}
