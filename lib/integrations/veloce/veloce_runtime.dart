import 'dart:developer' as developer;

import 'argo_host_state_bridge.dart';

import 'dart:io';

import 'package:veloce_lua_core/veloce_lua_core.dart';
import 'package:veloce_lua_native/veloce_lua_native.dart';

/// Filesystem and native-library configuration for [VeloceRuntime].
final class VeloceRuntimeConfiguration {
  const VeloceRuntimeConfiguration({
    required this.pluginRoot,
    required this.storageDatabase,
    this.nativeLibraryPath,
    this.traceVehicleKey,
    this.hostStateDiagnostics = false,
  });

  /// Builds the production configuration from host environment variables.
  ///
  /// `VELOCE_PLUGIN_DIR`, `VELOCE_PLUGIN_STORAGE`, and `VELOCE_LUA_LIBRARY`
  /// override their respective defaults. Without an explicit plugin override,
  /// [defaultPluginRoot] may bind an external vehicle integration. Plugin and
  /// storage directories otherwise live in the current user's mutable
  /// application-data directory, outside the packaged application image.
  /// `VELOCE_TRACE_VEHICLE_KEY` optionally enables terminal signal tracing.
  factory VeloceRuntimeConfiguration.fromEnvironment({
    Map<String, String>? environment,
    Directory? defaultPluginRoot,
  }) {
    final values = environment ?? Platform.environment;
    final pluginRootOverride = _optionalPath(values, 'VELOCE_PLUGIN_DIR');
    final pluginRoot = pluginRootOverride == null
        ? defaultPluginRoot?.absolute
        : Directory(pluginRootOverride).absolute;
    final storageRoot = _optionalPath(values, 'VELOCE_PLUGIN_STORAGE');
    final applicationData = pluginRoot == null || storageRoot == null
        ? _applicationDataDirectory(values)
        : null;

    return VeloceRuntimeConfiguration(
      pluginRoot:
          pluginRoot ??
          Directory.fromUri(applicationData!.uri.resolve('plugins/')).absolute,
      storageDatabase: File.fromUri(
        Directory(
          storageRoot ??
              Directory.fromUri(applicationData!.uri.resolve('storage/')).path,
        ).absolute.uri.resolve('plugins.sqlite3'),
      ),
      nativeLibraryPath: _optionalPath(values, 'VELOCE_LUA_LIBRARY'),
      traceVehicleKey: _optionalPath(values, 'VELOCE_TRACE_VEHICLE_KEY'),
      hostStateDiagnostics: values['ARGO_HOST_STATE_DIAGNOSTICS'] == '1',
    );
  }

  final Directory pluginRoot;
  final File storageDatabase;
  final String? nativeLibraryPath;
  final String? traceVehicleKey;
  final bool hostStateDiagnostics;

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
    required this.hostState,
    required this.vehicleDataBus,
    required this.configuration,
    required this.initialDiscovery,
    required this._storageProvider,
    required this._canProvider,
    required this._traceSubscription,
  });

  final PluginManager pluginManager;
  final ArgoHostStateBridge hostState;
  final VehicleDataBus vehicleDataBus;
  final VeloceRuntimeConfiguration configuration;
  final PluginDiscoveryResult initialDiscovery;
  final SqlitePluginStorageProvider _storageProvider;
  final CanProvider _canProvider;
  final VehicleDataSubscription? _traceSubscription;

  Future<void>? _shutdownFuture;

  bool get isShutDown => _shutdownFuture != null;

  static Future<VeloceRuntime> start({
    VeloceRuntimeConfiguration? configuration,
    CanProvider? canProvider,
    String? canProviderDescription,
  }) async {
    final resolvedConfiguration =
        configuration ?? VeloceRuntimeConfiguration.fromEnvironment();
    final vehicleDataBus = VehicleDataBus();
    final storageProvider = SqlitePluginStorageProvider(
      databaseFile: resolvedConfiguration.storageDatabase,
    );
    final resolvedCanProvider = canProvider ?? _UnavailableCanProvider();
    final capabilityManager = ArgoHostStateBridge.capabilityManager();
    final hostState = ArgoHostStateBridge(
      diagnostics: resolvedConfiguration.hostStateDiagnostics,
    );
    if (resolvedCanProvider.writesEnabled) {
      capabilityManager.setHostCapabilityEnabled(
        BuiltInCapabilities.canWrite,
        enabled: true,
      );
    }
    PluginManager? pluginManager;
    VehicleDataSubscription? traceSubscription;

    try {
      final traceKey = resolvedConfiguration.traceVehicleKey;
      if (traceKey != null) {
        traceSubscription = vehicleDataBus.subscribe(
          ownerId: 'argo.development.vehicle-trace',
          key: traceKey,
          emitCurrent: true,
          handler: (point) {
            stdout.writeln('[Veloce vehicle] ${point.key}=${point.value}');
            developer.log(
              '${point.key}=${point.value}',
              name: 'argo.veloce.vehicle',
              time: point.timestamp,
              sequenceNumber: point.sequence,
            );
          },
        );
      }
      pluginManager = PluginManager(
        pluginRoot: resolvedConfiguration.pluginRoot,
        runtimeFactory: IsolatedNativeLuaRuntimeFactory(
          libraryPath: resolvedConfiguration.nativeLibraryPath,
        ),
        vehicleDataBus: vehicleDataBus,
        canProvider: resolvedCanProvider,
        storageProvider: storageProvider,
        capabilityManager: capabilityManager,
        loader: ArgoHostStateBridge.loader(),
      );
      hostState.register(pluginManager);
      final discovery = await pluginManager.discover();
      await pluginManager.startWatching();
      if (traceKey != null) {
        _writeStartupDiagnostics(
          traceKey: traceKey,
          canProviderDescription:
              canProviderDescription ??
              (canProvider == null
                  ? 'disabled (fail-closed)'
                  : resolvedCanProvider.runtimeType.toString()),
          pluginRoot: resolvedConfiguration.pluginRoot,
          plugins: pluginManager.currentPlugins,
        );
      }

      return VeloceRuntime._(
        pluginManager: pluginManager,
        hostState: hostState,
        vehicleDataBus: vehicleDataBus,
        configuration: resolvedConfiguration,
        initialDiscovery: discovery,
        storageProvider: storageProvider,
        canProvider: resolvedCanProvider,
        traceSubscription: traceSubscription,
      );
    } on Object catch (error, stackTrace) {
      await hostState.close();
      await _closeAfterStartupFailure(
        pluginManager: pluginManager,
        storageProvider: storageProvider,
        vehicleDataBus: vehicleDataBus,
        canProvider: resolvedCanProvider,
        traceSubscription: traceSubscription,
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// Stops CAN input, unloads plugins, then releases host-owned resources.
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

    await close(hostState.close);
    await close(_canProvider.close);
    await close(pluginManager.close);
    if (_traceSubscription case final subscription?) {
      await close(subscription.cancel);
    }
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
    required VehicleDataSubscription? traceSubscription,
  }) async {
    try {
      await canProvider.close();
    } on Object {
      // Preserve the startup failure while still releasing other resources.
    }
    try {
      await pluginManager?.close();
    } on Object {
      // Preserve the startup failure while still releasing other resources.
    }
    try {
      await traceSubscription?.cancel();
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

  static void _writeStartupDiagnostics({
    required String traceKey,
    required String canProviderDescription,
    required Directory pluginRoot,
    required List<PluginRecord> plugins,
  }) {
    stdout.writeln('[Veloce] vehicle trace key: $traceKey');
    stdout.writeln('[Veloce] CAN provider: $canProviderDescription');
    stdout.writeln('[Veloce] plugin root: ${pluginRoot.path}');
    if (plugins.isEmpty) {
      stdout.writeln('[Veloce] discovered plugins: none');
      return;
    }
    for (final plugin in plugins) {
      stdout.writeln(
        '[Veloce] plugin ${plugin.manifest.id}: '
        'PluginState.${plugin.state.name}',
      );
      if (plugin.state == PluginState.failed && plugin.latestError != null) {
        stdout.writeln(
          '[Veloce] plugin ${plugin.manifest.id} latestError: '
          '${plugin.latestError}',
        );
      }
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
  Future<void> removeOwner(String ownerId) async {}

  @override
  Future<void> close() async {
    _closed = true;
  }

  void _ensureOpen() {
    if (_closed) throw StateError('CAN provider is closed.');
  }
}
