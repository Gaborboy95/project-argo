import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/widgets.dart';

import '../core/runtime/argo_runtime_mode.dart';
import '../core/settings/app_setting_keys.dart';
import '../core/settings/json_file_settings_store.dart';
import '../core/settings/settings_service.dart';
import '../core/settings/settings_store.dart';
import '../core/services/service_registry.dart';
import '../integrations/simulation/simulation_scenario.dart';
import '../integrations/simulation/simulation_service.dart';
import '../integrations/veloce/veloce_can_provider_selection.dart';
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
  final runtimeMode = ArgoRuntimeMode.fromEnvironment(processEnvironment);
  final scenarioFile = runtimeMode == ArgoRuntimeMode.simulation
      ? _configuredScenarioFile(processEnvironment)
      : null;
  final configuredScenario = scenarioFile == null
      ? null
      : await SimulationScenario.load(scenarioFile);
  if (runtimeMode == ArgoRuntimeMode.simulation) {
    stdout.writeln('[Argo simulation] enabled');
    if (scenarioFile != null) {
      stdout.writeln('[Argo simulation] scenario: ${scenarioFile.path}');
    }
  }

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
  SimulationService? simulation;
  try {
    final veloceConfiguration = VeloceRuntimeConfiguration.fromEnvironment(
      environment: processEnvironment,
    );
    final canSelection = await selectVeloceCanProvider(
      runtimeMode: runtimeMode,
      environment: processEnvironment,
    );
    veloceRuntime = await VeloceRuntime.start(
      configuration: veloceConfiguration,
      canProvider: canSelection.provider,
      canProviderDescription: canSelection.description,
    );
    final services = ServiceRegistry()
      ..register(settings)
      ..register(veloceRuntime);
    final simulationProvider = canSelection.simulationProvider;
    if (simulationProvider != null) {
      simulation = SimulationService(
        canProvider: simulationProvider,
        vehicleDataBus: veloceRuntime.vehicleDataBus,
      );
      services.register(simulation);
      if (configuredScenario != null) {
        await simulation.startScenario(configuredScenario);
      }
    }
    final moduleRegistry = AppModuleRegistry();
    registerBuiltInAppModules(moduleRegistry);
    final environment = ArgoEnvironment(
      services: services,
      moduleRegistry: moduleRegistry,
    );

    return VeloceRuntimeLifecycle(
      runtime: services.get<VeloceRuntime>(),
      beforeShutdown: () => _shutdownBeforeVeloce(
        simulation: simulation,
        settings: services.get<SettingsService>(),
      ),
      child: ArgoApp(environment: environment),
    );
  } on Object catch (error, stackTrace) {
    try {
      await _shutdownBeforeVeloce(simulation: simulation, settings: settings);
    } on Object {
      // Preserve the bootstrap error.
    }
    try {
      await veloceRuntime?.shutdown();
    } on Object {
      // Preserve the bootstrap error.
    }
    Error.throwWithStackTrace(error, stackTrace);
  }
}

File? _configuredScenarioFile(Map<String, String> environment) {
  final path = environment['ARGO_SIMULATION_SCENARIO']?.trim();
  return path == null || path.isEmpty ? null : File(path).absolute;
}

Future<void> _shutdownBeforeVeloce({
  required SimulationService? simulation,
  required SettingsService settings,
}) async {
  Object? firstError;
  StackTrace? firstStackTrace;

  Future<void> run(Future<void> Function() operation) async {
    try {
      await operation();
    } on Object catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
  }

  if (simulation != null) await run(simulation.stopScenario);
  await run(settings.close);
  if (firstError case final error?) {
    Error.throwWithStackTrace(error, firstStackTrace!);
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
