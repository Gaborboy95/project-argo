import 'package:flutter/material.dart';

import '../../core/power/head_unit_power_service.dart';
import '../../core/audio/audio_service.dart';
import '../../core/projection/projection_service.dart';
import '../../core/vehicle/vehicle_data_service.dart';
import '../../features/climate/climate_page.dart';
import '../../features/home/home_page.dart';
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
        builder: (_, _) => const HomePage(),
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
        builder: (_, services) =>
            MediaPage(projection: services.get<ProjectionService>()),
      ),
    )
    ..register(
      AppModule(
        id: 'settings',
        label: 'Settings',
        icon: Icons.settings_outlined,
        builder: (_, services) =>
            SettingsPage(audio: services.get<AudioService>()),
      ),
    );
}
