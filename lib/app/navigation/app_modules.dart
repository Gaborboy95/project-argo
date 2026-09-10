import '../../core/lifecycle/application_exit_service.dart';
import '../../features/calls/calls_page.dart';
import '../../core/connectivity/connectivity_service.dart';
import '../../core/settings/settings_service.dart';
import '../../core/media/media_session_service.dart';

import 'package:flutter/material.dart';

import '../../core/power/head_unit_power_service.dart';
import '../../core/audio/audio_service.dart';
import '../../core/projection/projection_service.dart';
import '../../core/projection/projection_settings_service.dart';
import '../../core/projection/projection_presentation_options.dart';
import '../../core/projection/projection_render_test.dart';
import '../../core/vehicle/vehicle_data_service.dart';
import '../../features/climate/climate_page.dart';
import '../../features/projection/projection_page.dart';
import '../../features/media/media_page.dart';
import '../../features/parking/parking_page.dart';
import '../../features/settings/settings_page.dart';
import '../../features/vehicle/vehicle_page.dart';
import 'app_module.dart';
import 'app_module_registry.dart';

void registerBuiltInAppModules(AppModuleRegistry registry) {
  registry
    ..register(
      AppModule(
        id: 'home',
        label: 'Home',
        icon: Icons.home_outlined,
        builder: (_, services) => ProjectionPage(
          projection: services.get<ProjectionService>(),
          geometryDiagnostics:
              services.contains<ProjectionPresentationOptions>() &&
              services.get<ProjectionPresentationOptions>().geometryDiagnostics,
          rendererTest:
              services.contains<ProjectionRenderTest>() &&
              services.get<ProjectionRenderTest>().enabled,
        ),
      ),
    )
    ..register(
      AppModule(
        id: 'vehicle',
        label: 'Vehicle',
        icon: Icons.directions_car_outlined,
        builder: (_, services) => VehiclePage(
          vehicleData: services.get<VehicleDataService>(),
          power: services.get<HeadUnitPowerService>(),
        ),
      ),
    )
    ..register(
      AppModule(
        id: 'climate',
        label: 'Climate',
        icon: Icons.air_outlined,
        builder: (_, _) => const ClimatePage(),
      ),
    )
    ..register(
      AppModule(
        id: 'parking',
        label: 'Parking',
        icon: Icons.local_parking_outlined,
        builder: (_, _) => const ParkingPage(),
      ),
    )
    ..register(
      AppModule(
        id: 'media',
        label: 'Media',
        icon: Icons.music_note_outlined,
        builder: (_, services) => MediaPage(
          connectivity: services.contains<ConnectivityService>()
              ? services.get<ConnectivityService>()
              : null,
          projection: services.get<ProjectionService>(),
          media: services.contains<MediaSessionService>()
              ? services.get<MediaSessionService>()
              : null,
        ),
      ),
    )
    ..register(
      AppModule(
        id: 'settings',
        label: 'Settings',
        icon: Icons.settings_outlined,
        builder: (_, services) => SettingsPage(
          exit: services.contains<ApplicationExitService>()
              ? services.get<ApplicationExitService>()
              : null,
          connectivity: services.contains<ConnectivityService>()
              ? services.get<ConnectivityService>()
              : null,
          audio: services.get<AudioService>(),
          settings: services.get<SettingsService>(),
          projectionSettings: services.contains<ProjectionSettingsService>()
              ? services.get<ProjectionSettingsService>()
              : null,
        ),
      ),
    );
  registry.register(
    AppModule(
      id: 'calls',
      label: 'Calls',
      icon: Icons.phone_outlined,
      builder: (_, services) => CallsPage(
        service: services.contains<ConnectivityService>()
            ? services.get<ConnectivityService>()
            : null,
      ),
    ),
  );
}
