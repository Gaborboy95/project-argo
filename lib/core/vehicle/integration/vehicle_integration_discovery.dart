import 'dart:io';

import 'vehicle_integration_bundle.dart';
import 'vehicle_integration_manifest.dart';

/// A non-fatal malformed integration discovered alongside valid bundles.
final class VehicleIntegrationDiscoveryFailure {
  const VehicleIntegrationDiscoveryFailure({
    required this.bundleDirectory,
    required this.error,
    required this.stackTrace,
    this.profileId,
  });

  final Directory bundleDirectory;
  final String? profileId;
  final Object error;
  final StackTrace stackTrace;
}

final class VehicleIntegrationDiscoveryResult {
  VehicleIntegrationDiscoveryResult({
    required Iterable<VehicleIntegrationBundle> bundles,
    required Iterable<VehicleIntegrationDiscoveryFailure> failures,
  }) : bundles = List.unmodifiable(bundles),
       failures = List.unmodifiable(failures);

  const VehicleIntegrationDiscoveryResult.empty()
    : bundles = const [],
      failures = const [];

  final List<VehicleIntegrationBundle> bundles;
  final List<VehicleIntegrationDiscoveryFailure> failures;
}

final class DuplicateVehicleIntegrationProfileException implements Exception {
  const DuplicateVehicleIntegrationProfileException({
    required this.profileId,
    required this.firstDirectory,
    required this.secondDirectory,
  });

  final String profileId;
  final Directory firstDirectory;
  final Directory secondDirectory;

  @override
  String toString() =>
      'Duplicate external vehicle profile "$profileId" in '
      '"${firstDirectory.path}" and "${secondDirectory.path}".';
}

/// Discovers only immediate, real child directories of an explicit root.
final class VehicleIntegrationDiscovery {
  const VehicleIntegrationDiscovery([
    this._manifestParser = const VehicleIntegrationManifestParser(),
  ]);

  final VehicleIntegrationManifestParser _manifestParser;

  Future<VehicleIntegrationDiscoveryResult> discover(Directory root) async {
    if (!root.isAbsolute) {
      throw ArgumentError.value(
        root.path,
        'root',
        'Vehicle integration directory must be an absolute path',
      );
    }
    if (!await root.exists()) {
      throw FileSystemException(
        'Vehicle integration directory does not exist',
        root.path,
      );
    }

    final resolvedRoot = Directory(await root.resolveSymbolicLinks());
    final candidates = <Directory>[];
    await for (final entity in resolvedRoot.list(followLinks: false)) {
      if (entity is Directory) candidates.add(entity);
    }
    candidates.sort((left, right) => left.path.compareTo(right.path));

    final bundles = <VehicleIntegrationBundle>[];
    final failures = <VehicleIntegrationDiscoveryFailure>[];
    final bundlesById = <String, VehicleIntegrationBundle>{};
    for (final candidate in candidates) {
      try {
        final bundle = await _loadBundle(resolvedRoot, candidate);
        final existing = bundlesById[bundle.profile.id];
        if (existing != null) {
          throw DuplicateVehicleIntegrationProfileException(
            profileId: bundle.profile.id,
            firstDirectory: existing.rootDirectory,
            secondDirectory: bundle.rootDirectory,
          );
        }
        bundlesById[bundle.profile.id] = bundle;
        bundles.add(bundle);
      } on DuplicateVehicleIntegrationProfileException {
        rethrow;
      } on Object catch (error, stackTrace) {
        failures.add(
          VehicleIntegrationDiscoveryFailure(
            bundleDirectory: candidate.absolute,
            profileId: error is VehicleIntegrationManifestException
                ? error.profileId
                : null,
            error: error,
            stackTrace: stackTrace,
          ),
        );
      }
    }
    return VehicleIntegrationDiscoveryResult(
      bundles: bundles,
      failures: failures,
    );
  }

  Future<VehicleIntegrationBundle> _loadBundle(
    Directory root,
    Directory candidate,
  ) async {
    final resolvedBundle = Directory(await candidate.resolveSymbolicLinks());
    _requireContained(root.path, resolvedBundle.path, 'integration bundle');

    final manifest = File.fromUri(resolvedBundle.uri.resolve('vehicle.json'));
    if (await FileSystemEntity.type(manifest.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw FileSystemException(
        'Integration bundle does not contain a regular vehicle.json file',
        manifest.path,
      );
    }

    final pluginDirectory = Directory.fromUri(
      resolvedBundle.uri.resolve('plugins/'),
    );
    if (await FileSystemEntity.type(pluginDirectory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw FileSystemException(
        'Integration bundle does not contain a regular plugins directory',
        pluginDirectory.path,
      );
    }
    final resolvedPlugins = Directory(
      await pluginDirectory.resolveSymbolicLinks(),
    );
    _requireContained(
      resolvedBundle.path,
      resolvedPlugins.path,
      'integration plugin directory',
    );

    return VehicleIntegrationBundle(
      profile: await _manifestParser.load(manifest),
      rootDirectory: resolvedBundle,
      velocePluginDirectory: resolvedPlugins,
    );
  }

  static void _requireContained(
    String rootPath,
    String childPath,
    String description,
  ) {
    final root = _normalizedWithSeparator(rootPath);
    final child = _normalized(childPath);
    if (!child.startsWith(root)) {
      throw FileSystemException(
        '$description resolves outside its allowed directory',
        childPath,
      );
    }
  }

  static String _normalizedWithSeparator(String path) {
    final normalized = _normalized(path);
    return normalized.endsWith(Platform.pathSeparator)
        ? normalized
        : '$normalized${Platform.pathSeparator}';
  }

  static String _normalized(String path) =>
      Platform.isWindows ? path.toLowerCase() : path;
}

/// Resolves the one explicitly configured integration root without relying on
/// the process working directory.
Directory? vehicleIntegrationsDirectoryFromEnvironment(
  Map<String, String> environment,
) {
  final configured = environment['ARGO_VEHICLE_INTEGRATIONS_DIR'];
  if (configured == null || configured.trim().isEmpty) return null;
  final directory = Directory(configured.trim());
  if (!directory.isAbsolute) {
    throw ArgumentError.value(
      configured,
      'ARGO_VEHICLE_INTEGRATIONS_DIR',
      'Must be an absolute path',
    );
  }
  return directory;
}
