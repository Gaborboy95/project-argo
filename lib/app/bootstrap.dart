import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/widgets.dart';

import '../core/settings/app_setting_keys.dart';
import '../core/settings/json_file_settings_store.dart';
import '../core/settings/settings_service.dart';
import '../core/settings/settings_store.dart';
import '../core/services/service_registry.dart';
import '../integrations/veloce/socket_can_provider.dart';
import '../integrations/veloce/veloce_runtime.dart';
import '../integrations/veloce/veloce_runtime_lifecycle.dart';
import 'app.dart';
import 'argo_environment.dart';
import 'navigation/app_module_registry.dart';
import 'navigation/app_modules.dart';

/// Composes Project Argo and starts its application-owned integrations.
Future<Widget> bootstrapArgoApplication({
  required Map<String, String> processEnvironment,
}) async {
  final settingsDiagnostics = _reportSettingsDiagnostic;
  final settings = await SettingsService.load(
    schema: AppSettingKeys.createSchema(),
    store: JsonFileSettingsStore(
      file: ArgoSettingsFile.fromEnvironment(processEnvironment),
      onDiagnostic: settingsDiagnostics,
    ),
    onDiagnostic: settingsDiagnostics,
  );
  VeloceRuntime? veloceRuntime;
  try {
    final veloceConfiguration = VeloceRuntimeConfiguration.fromEnvironment(
      environment: processEnvironment,
    );
    final socketCanConfiguration = SocketCanConfiguration.fromEnvironment(
      processEnvironment,
    );
    final canProvider = socketCanConfiguration == null
        ? null
        : await SocketCanProvider.start(socketCanConfiguration);
    veloceRuntime = await VeloceRuntime.start(
      configuration: veloceConfiguration,
      canProvider: canProvider,
      canProviderDescription: socketCanConfiguration == null
          ? null
          : 'SocketCAN(interface=${socketCanConfiguration.interfaceName}, '
                'bus=${socketCanConfiguration.logicalBus}, '
                'writes=${socketCanConfiguration.writesEnabled})',
    );
    final services = ServiceRegistry()
      ..register(settings)
      ..register(veloceRuntime);
    final moduleRegistry = AppModuleRegistry();
    registerBuiltInAppModules(moduleRegistry);
    final environment = ArgoEnvironment(
      services: services,
      moduleRegistry: moduleRegistry,
    );

    return VeloceRuntimeLifecycle(
      runtime: services.get<VeloceRuntime>(),
      beforeShutdown: services.get<SettingsService>().close,
      child: ArgoApp(environment: environment),
    );
  } on Object catch (error, stackTrace) {
    try {
      await veloceRuntime?.shutdown();
    } on Object {
      // Preserve the bootstrap error.
    }
    try {
      await settings.close();
    } on Object {
      // Preserve the bootstrap error.
    }
    Error.throwWithStackTrace(error, stackTrace);
  }
}

void _reportSettingsDiagnostic(SettingsDiagnostic diagnostic) {
  stderr.writeln('[Argo settings] ${diagnostic.message}');
  developer.log(
    diagnostic.message,
    name: 'argo.settings',
    error: diagnostic.error,
    stackTrace: diagnostic.stackTrace,
  );
}
