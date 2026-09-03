import 'dart:io';

import 'package:veloce_lua_core/veloce_lua_core.dart';
import 'package:veloce_lua_native/veloce_lua_native.dart';

/// Filesystem and native-library configuration for [VeloceRuntime].
final class VeloceRuntimeConfiguration {
  const VeloceRuntimeConfiguration({
    required this.pluginRoot,
    required this.storageDatabase,
    this.nativeLibraryPath,
  });

  /// Builds the production configuration from host environment variables.
  ///
  /// `VELOCE_PLUGIN_DIR`, `VELOCE_PLUGIN_STORAGE`, and
  /// `VELOCE_LUA_LIBRARY` override their respective defaults. Plugin and
  /// storage directories otherwise live in the current user's mutable
  /// application-data directory, outside the packaged application image.
  factory VeloceRuntimeConfiguration.fromEnvironment({
    Map<String, String>? environment,
  }) {
    final values = environment ?? Platform.environment;
    final pluginRoot = _optionalPath(values, 'VELOCE_PLUGIN_DIR');
    final storageRoot = _optionalPath(values, 'VELOCE_PLUGIN_STORAGE');
    final applicationData = pluginRoot == null || storageRoot == null
        ? _applicationDataDirectory(values)
        : null;

    return VeloceRuntimeConfiguration(
      pluginRoot: Directory(
        pluginRoot ??
            Directory.fromUri(applicationData!.uri.resolve('plugins/')).path,
      ).absolute,
      storageDatabase: File.fromUri(
        Directory(
          storageRoot ??
              Directory.fromUri(applicationData!.uri.resolve('storage/')).path,
        ).absolute.uri.resolve('plugins.sqlite3'),
      ),
      nativeLibraryPath: _optionalPath(values, 'VELOCE_LUA_LIBRARY'),
    );
  }

  final Directory pluginRoot;
  final File storageDatabase;
  final String? nativeLibraryPath;

  static Directory _applicationDataDirectory(Map<String, String> environment) {
    final String? basePath;
    if (Platform.isWindows) {
      basePath = _optionalPath(environment, 'LOCALAPPDATA');
    } else if (Platform.isMacOS) {
      final home = _optionalPath(environment, 'HOME');
      basePath = home == null
          ? null
          : Directory.fromUri(
              Directory(home).uri.resolve('Library/Application Support/'),
            ).path;
    } else {
      final xdgDataHome = _optionalPath(environment, 'XDG_DATA_HOME');
      final home = _optionalPath(environment, 'HOME');
      basePath =
          xdgDataHome ??
          (home == null
              ? null
              : Directory.fromUri(Directory(home).uri.resolve('.local/share/'))
                    .path);
    }

    if (basePath == null) {
      throw StateError(
        'Could not resolve a writable application-data directory for Veloce.',
      );
    }

    return Directory.fromUri(
      Directory(basePath).absolute.uri.resolve('project-argo/veloce/'),
    );
  }

  static String? _optionalPath(Map<String, String> environment, String name) {
    final value = environment[name]?.trim();
    return value == null || value.isEmpty ? null : value;
  }
}

/// Owns the production Veloce plugin runtime and its application resources.
///
/// A future CAN integration can supply a [CanProvider] without coupling this
/// service to SocketCAN or to any vehicle-specific decoding. When supplied,
/// ownership of that provider transfers to this runtime.
final class VeloceRuntime {
  VeloceRuntime._({
    required this.pluginManager,
    required this.vehicleDataBus,
    required this.configuration,
    required this.initialDiscovery,
    required this._storageProvider,
    required this._canProvider,
  });

  final PluginManager pluginManager;
  final VehicleDataBus vehicleDataBus;
  final VeloceRuntimeConfiguration configuration;
  final PluginDiscoveryResult initialDiscovery;
  final SqlitePluginStorageProvider _storageProvider;
  final CanProvider _canProvider;

  Future<void>? _shutdownFuture;

  bool get isShutDown => _shutdownFuture != null;

  static Future<VeloceRuntime> start({
    VeloceRuntimeConfiguration? configuration,
    CanProvider? canProvider,
  }) async {
    final resolvedConfiguration =
        configuration ?? VeloceRuntimeConfiguration.fromEnvironment();
    final vehicleDataBus = VehicleDataBus();
    final storageProvider = SqlitePluginStorageProvider(
      databaseFile: resolvedConfiguration.storageDatabase,
    );
    final resolvedCanProvider = canProvider ?? _UnavailableCanProvider();
    PluginManager? pluginManager;

    try {
      pluginManager = PluginManager(
        pluginRoot: resolvedConfiguration.pluginRoot,
        runtimeFactory: IsolatedNativeLuaRuntimeFactory(
          libraryPath: resolvedConfiguration.nativeLibraryPath,
        ),
        vehicleDataBus: vehicleDataBus,
        canProvider: resolvedCanProvider,
        storageProvider: storageProvider,
      );
      final discovery = await pluginManager.discover();
      await pluginManager.startWatching();

      return VeloceRuntime._(
        pluginManager: pluginManager,
        vehicleDataBus: vehicleDataBus,
        configuration: resolvedConfiguration,
        initialDiscovery: discovery,
        storageProvider: storageProvider,
        canProvider: resolvedCanProvider,
      );
    } on Object catch (error, stackTrace) {
      await _closeAfterStartupFailure(
        pluginManager: pluginManager,
        storageProvider: storageProvider,
        vehicleDataBus: vehicleDataBus,
        canProvider: resolvedCanProvider,
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// Stops watching, unloads plugins, then releases host-owned resources.
  Future<void> shutdown() => _shutdownFuture ??= _shutdown();

  Future<void> _shutdown() async {
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> close(Future<void> Function() operation) async {
      try {
        await operation();
      } on Object catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    await close(pluginManager.close);
    await close(_canProvider.close);
    await close(_storageProvider.close);
    await close(vehicleDataBus.close);

    if (firstError case final error?) {
      Error.throwWithStackTrace(error, firstStackTrace!);
    }
  }

  static Future<void> _closeAfterStartupFailure({
    required PluginManager? pluginManager,
    required SqlitePluginStorageProvider storageProvider,
    required VehicleDataBus vehicleDataBus,
    required CanProvider canProvider,
  }) async {
    try {
      await pluginManager?.close();
    } on Object {
      // Preserve the startup failure while still releasing other resources.
    }
    try {
      await canProvider.close();
    } on Object {
      // Preserve the startup failure while still releasing other resources.
    }
    try {
      await storageProvider.close();
    } on Object {
      // Preserve the startup failure while still releasing other resources.
    }
    try {
      await vehicleDataBus.close();
    } on Object {
      // Preserve the startup failure.
    }
  }
}

/// Safe pre-SocketCAN state: CAN I/O is unavailable rather than simulated.
final class _UnavailableCanProvider implements CanProvider {
  var _closed = false;

  @override
  bool get writesEnabled => false;

  @override
  Future<CanSubscription> subscribe({
    required String ownerId,
    required CanFilter filter,
    required CanFrameHandler onFrame,
  }) async {
    _ensureOpen();
    throw StateError('No CAN transport is configured.');
  }

  @override
  Future<void> send({required String ownerId, required CanFrame frame}) async {
    _ensureOpen();
    throw CanWriteDisabledException(pluginId: ownerId);
  }

  @override
  Future<void> removeOwner(String ownerId) async {
    _ensureOpen();
  }

  @override
  Future<void> close() async {
    _closed = true;
  }

  void _ensureOpen() {
    if (_closed) throw StateError('CAN provider is closed.');
  }
}
