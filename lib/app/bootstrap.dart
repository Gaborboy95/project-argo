import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:veloce_lua_core/veloce_lua_core.dart';

import '../core/diagnostics/diagnostics_service.dart';
import '../core/lifecycle/app_lifecycle_coordinator.dart';
import '../core/lifecycle/argo_lifecycle_host.dart';
import '../core/runtime/argo_runtime_mode.dart';
import '../core/settings/app_setting_keys.dart';
import '../core/settings/json_file_settings_store.dart';
import '../core/settings/settings_service.dart';
import '../core/settings/settings_store.dart';
import '../core/services/service_registry.dart';
import '../core/vehicle/vehicle_data_service.dart';
import '../core/vehicle/vehicle_transport_lifecycle.dart';
import '../core/vehicle/integration/vehicle_integration_bundle.dart';
import '../core/vehicle/integration/vehicle_integration_discovery.dart';
import '../core/vehicle/vehicle_profile_registry.dart';
import '../core/vehicle/vehicle_profiles.dart';
import '../integrations/simulation/simulation_scenario.dart';
import '../integrations/simulation/simulation_service.dart';
import '../integrations/veloce/veloce_can_provider_selection.dart';
import '../integrations/veloce/veloce_runtime.dart';
import '../integrations/veloce/veloce_vehicle_data_service.dart';
import 'app.dart';
import 'audio_composition.dart';
import 'argo_environment.dart';
import 'head_unit_power_composition.dart';
import 'host_power_composition.dart';
import 'navigation/app_module_registry.dart';
import 'navigation/app_modules.dart';
import 'vehicle_profile_composition.dart';

/// Composes Project Argo and starts its application-owned integrations.
Future<Widget> bootstrapArgoApplication({
  required Map<String, String> processEnvironment,
  DiagnosticsService? diagnosticsService,
}) {
  final diagnostics = diagnosticsService ?? DiagnosticsService();
  final lifecycle = AppLifecycleCoordinator(
    onCleanupFailure: (failure) {
      diagnostics.error(
        'app.lifecycle',
        'Cleanup for "${failure.registrationName}" failed.',
        error: failure.error,
        stackTrace: failure.stackTrace,
      );
    },
  );
  return lifecycle.runStartup(() async {
    final runtimeMode = ArgoRuntimeMode.fromEnvironment(processEnvironment);
    final integrationRoot = vehicleIntegrationsDirectoryFromEnvironment(
      processEnvironment,
    );
    final integrationDiscovery = integrationRoot == null
        ? const VehicleIntegrationDiscoveryResult.empty()
        : await const VehicleIntegrationDiscovery().discover(integrationRoot);
    for (final failure in integrationDiscovery.failures) {
      diagnostics.warning(
        'vehicle.integration.discovery',
        'Could not load vehicle integration bundle at '
            '"${failure.bundleDirectory.path}".',
        error: failure.error,
        stackTrace: failure.stackTrace,
      );
    }
    final vehicleProfiles = VehicleProfileRegistry();
    registerBuiltInVehicleProfiles(vehicleProfiles);
    final services = ServiceRegistry();
    final activeProfile = registerVehicleProfileServices(
      services: services,
      profiles: vehicleProfiles,
      environment: processEnvironment,
      externalIntegrations: integrationDiscovery.bundles,
      discoveryFailures: integrationDiscovery.failures,
    );
    final activeIntegration = _integrationForProfile(
      integrationDiscovery.bundles,
      activeProfile.id,
    );
    diagnostics.info(
      'vehicle.profile',
      'Selected vehicle profile "${activeProfile.id}" '
          '(${activeProfile.displayName}).',
    );
    if (activeIntegration != null) {
      diagnostics.info(
        'vehicle.integration',
        'Selected external vehicle integration '
            '"${activeIntegration.rootDirectory.path}".',
      );
    }
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

    void settingsDiagnostics(SettingsDiagnostic diagnostic) {
      _reportSettingsDiagnostic(diagnostics, diagnostic);
    }

    final settings = await SettingsService.load(
      schema: AppSettingKeys.createSchema(),
      store: JsonFileSettingsStore(
        file: ArgoSettingsFile.fromEnvironment(processEnvironment),
        onDiagnostic: settingsDiagnostics,
      ),
      onDiagnostic: settingsDiagnostics,
    );
    lifecycle.registerShutdown(
      name: 'settings',
      phase: AppShutdownPhase.persistState,
      shutdown: settings.close,
    );

    final veloceConfiguration = VeloceRuntimeConfiguration.fromEnvironment(
      environment: processEnvironment,
      defaultPluginRoot: activeIntegration?.velocePluginDirectory,
    );
    diagnostics.info(
      'veloce.configuration',
      'Resolved Veloce plugin root '
          '"${veloceConfiguration.pluginRoot.path}".',
    );
    final canSelection = await selectVeloceCanProvider(
      runtimeMode: runtimeMode,
      environment: processEnvironment,
      onSocketCanError: (error, stackTrace) {
        diagnostics.error(
          'veloce.socketcan',
          'SocketCAN provider reported an error.',
          error: error,
          stackTrace: stackTrace,
        );
      },
      onCanHandlerError: (error, stackTrace, ownerId) {
        diagnostics.error(
          'veloce.can',
          'CAN subscriber "$ownerId" reported an error.',
          error: error,
          stackTrace: stackTrace,
        );
      },
    );
    final canProviderCleanup = canSelection.provider == null
        ? null
        : lifecycle.registerShutdown(
            name: 'veloce.canProvider',
            shutdown: canSelection.provider!.close,
          );
    final veloceRuntime = await VeloceRuntime.start(
      configuration: veloceConfiguration,
      canProvider: canSelection.provider,
      canProviderDescription: canSelection.description,
    );
    canProviderCleanup?.unregister();
    lifecycle.registerShutdown(
      name: 'veloce.runtime',
      shutdown: veloceRuntime.shutdown,
    );
    _recordPluginStartupDiagnostics(diagnostics, veloceRuntime);
    final vehicleData = VeloceVehicleDataService(veloceRuntime.vehicleDataBus);

    services
      ..register(diagnostics)
      ..register(settings)
      ..register(veloceRuntime)
      ..register<VehicleDataService>(vehicleData)
      ..register<VehicleTransportLifecycle>(canSelection.transportLifecycle);
    registerHeadUnitPowerService(
      services: services,
      lifecycle: lifecycle,
      diagnostics: diagnostics,
    );
    await registerHostPowerServices(
      services: services,
      lifecycle: lifecycle,
      diagnostics: diagnostics,
      environment: processEnvironment,
      activeVehicleIntegration: activeIntegration,
      transportLifecycle: canSelection.transportLifecycle,
    );
    await registerAudioServices(
      services: services,
      lifecycle: lifecycle,
      diagnostics: diagnostics,
      environment: processEnvironment,
      activeVehicleIntegration: activeIntegration,
    );
    final simulationProvider = canSelection.simulationProvider;
    if (simulationProvider != null) {
      final simulation = SimulationService(
        canProvider: simulationProvider,
        vehicleDataBus: veloceRuntime.vehicleDataBus,
        onPlaybackError: (error, stackTrace) {
          diagnostics.error(
            'simulation.playback',
            'Simulation scenario playback failed.',
            error: error,
            stackTrace: stackTrace,
          );
        },
      );
      lifecycle.registerShutdown(
        name: 'simulation.playback',
        phase: AppShutdownPhase.stopActivity,
        shutdown: simulation.stopScenario,
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

    return ArgoLifecycleHost(
      coordinator: lifecycle,
      child: ArgoApp(environment: environment),
    );
  });
}

VehicleIntegrationBundle? _integrationForProfile(
  Iterable<VehicleIntegrationBundle> integrations,
  String profileId,
) {
  for (final integration in integrations) {
    if (integration.profile.id == profileId) return integration;
  }
  return null;
}

File? _configuredScenarioFile(Map<String, String> environment) {
  final path = environment['ARGO_SIMULATION_SCENARIO']?.trim();
  return path == null || path.isEmpty ? null : File(path).absolute;
}

void _reportSettingsDiagnostic(
  DiagnosticsService diagnostics,
  SettingsDiagnostic diagnostic,
) {
  diagnostics.warning(
    'settings',
    diagnostic.message,
    error: diagnostic.error,
    stackTrace: diagnostic.stackTrace,
  );
  stderr.writeln('[Argo settings] ${diagnostic.message}');
  developer.log(
    diagnostic.message,
    name: 'argo.settings',
    error: diagnostic.error,
    stackTrace: diagnostic.stackTrace,
  );
}

void _recordPluginStartupDiagnostics(
  DiagnosticsService diagnostics,
  VeloceRuntime runtime,
) {
  for (final failure in runtime.initialDiscovery.failures) {
    diagnostics.warning(
      'veloce.plugin.discovery',
      'Could not discover plugin at "${failure.directoryPath}".',
      error: failure.error,
      stackTrace: failure.error.causeStackTrace,
    );
  }
  for (final plugin in runtime.pluginManager.currentPlugins) {
    if (plugin.state != PluginState.failed) continue;
    diagnostics.error(
      'veloce.plugin.${plugin.manifest.id}',
      'Plugin failed to load.',
      error: plugin.latestError,
      stackTrace: plugin.latestError?.causeStackTrace,
    );
  }
}
