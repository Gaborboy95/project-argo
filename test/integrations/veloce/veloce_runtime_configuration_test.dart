import 'dart:io';

import 'package:argo/core/vehicle/integration/vehicle_integration_discovery.dart';
import 'package:argo/integrations/veloce/veloce_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('selected external bundle provides the default plugin root', () async {
    final integrationRoot = Directory('tool/vehicle_integrations').absolute;
    final discovery = await const VehicleIntegrationDiscovery().discover(
      integrationRoot,
    );
    final bundle = discovery.bundles.single;
    final storageRoot = await Directory.systemTemp.createTemp(
      'argo-storage-test-',
    );
    addTearDown(() => storageRoot.delete(recursive: true));

    final configuration = VeloceRuntimeConfiguration.fromEnvironment(
      environment: {'VELOCE_PLUGIN_STORAGE': storageRoot.path},
      defaultPluginRoot: bundle.velocePluginDirectory,
    );

    expect(configuration.pluginRoot.path, bundle.velocePluginDirectory.path);
  });

  test('explicit VELOCE_PLUGIN_DIR takes precedence over bundle plugins', () {
    final temporary = Directory.systemTemp.absolute;
    final bundlePlugins = Directory.fromUri(
      temporary.uri.resolve('bundle/plugins/'),
    );
    final override = Directory.fromUri(temporary.uri.resolve('override/'));
    final storage = Directory.fromUri(temporary.uri.resolve('storage/'));

    final configuration = VeloceRuntimeConfiguration.fromEnvironment(
      environment: {
        'VELOCE_PLUGIN_DIR': override.path,
        'VELOCE_PLUGIN_STORAGE': storage.path,
      },
      defaultPluginRoot: bundlePlugins,
    );

    expect(configuration.pluginRoot.path, override.absolute.path);
  });

  test('generic default plugin path remains backwards-compatible', () {
    final base = Directory.systemTemp.absolute;
    final environment = _applicationDataEnvironment(base.path);

    final configuration = VeloceRuntimeConfiguration.fromEnvironment(
      environment: environment,
    );

    final expectedDataRoot = Platform.isMacOS
        ? Directory.fromUri(
            base.uri.resolve(
              'Library/Application Support/project-argo/veloce/',
            ),
          )
        : Directory.fromUri(base.uri.resolve('project-argo/veloce/'));
    final expectedPlugins = Directory.fromUri(
      expectedDataRoot.uri.resolve('plugins/'),
    ).absolute;
    expect(configuration.pluginRoot.path, expectedPlugins.path);
  });
}

Map<String, String> _applicationDataEnvironment(String basePath) {
  if (Platform.isWindows) return {'LOCALAPPDATA': basePath};
  if (Platform.isMacOS) return {'HOME': basePath};
  return {'XDG_DATA_HOME': basePath};
}
