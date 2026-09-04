import 'dart:io';

import 'package:veloce_lua_core/veloce_lua_core.dart';

import '../../core/diagnostics/diagnostics_service.dart';

typedef VelocePluginLoadedLookup = bool Function(String pluginId);

/// Validates that a running plugin belongs to the selected external bundle.
final class VehicleIntegrationPluginAuthorizer {
  VehicleIntegrationPluginAuthorizer._({
    required this.pluginRegistry,
    required this.isPluginLoaded,
    required this.canonicalPluginRoot,
    required this.diagnostics,
  });

  static Future<VehicleIntegrationPluginAuthorizer> create({
    required PluginRegistry pluginRegistry,
    required VelocePluginLoadedLookup isPluginLoaded,
    required Directory? activeIntegrationPluginRoot,
    required DiagnosticsService diagnostics,
  }) async => VehicleIntegrationPluginAuthorizer._(
    pluginRegistry: pluginRegistry,
    isPluginLoaded: isPluginLoaded,
    canonicalPluginRoot: activeIntegrationPluginRoot == null
        ? null
        : Directory(await activeIntegrationPluginRoot.resolveSymbolicLinks()),
    diagnostics: diagnostics,
  );

  final PluginRegistry pluginRegistry;
  final VelocePluginLoadedLookup isPluginLoaded;
  final Directory? canonicalPluginRoot;
  final DiagnosticsService diagnostics;

  Future<bool> allows(String pluginId) async {
    final root = canonicalPluginRoot;
    if (root == null || !isPluginLoaded(pluginId)) return false;
    final record = pluginRegistry[pluginId];
    if (record == null || record.state != PluginState.running) return false;
    try {
      final directory = Directory(
        await Directory(record.directoryPath).resolveSymbolicLinks(),
      );
      final current = pluginRegistry[pluginId];
      if (!identical(record, current) ||
          !isPluginLoaded(pluginId) ||
          current?.state != PluginState.running) {
        return false;
      }
      return _isContained(root.path, directory.path);
    } on FileSystemException catch (error, stackTrace) {
      diagnostics.warning(
        'veloce.privileged-request',
        'Could not validate privileged request provenance for $pluginId.',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  static bool _isContained(String rootPath, String childPath) {
    final root = _normalize(rootPath);
    final prefix = root.endsWith(Platform.pathSeparator)
        ? root
        : '$root${Platform.pathSeparator}';
    return _normalize(childPath).startsWith(prefix);
  }

  static String _normalize(String path) =>
      Platform.isWindows ? path.toLowerCase() : path;
}
