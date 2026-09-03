import 'package:flutter/material.dart';

import '../../features/climate/climate_page.dart';
import '../../features/home/home_page.dart';
import '../../features/media/media_page.dart';
import '../../features/parking/parking_page.dart';
import '../../features/settings/settings_page.dart';
import '../../features/vehicle/vehicle_page.dart';
import 'app_module.dart';

final List<AppModule> appModules = [
  AppModule(
    id: 'home',
    label: 'Home',
    icon: Icons.home_outlined,
    builder: (_) => const HomePage(),
  ),
  AppModule(
    id: 'vehicle',
    label: 'Vehicle',
    icon: Icons.directions_car_outlined,
    builder: (_) => const VehiclePage(),
  ),
  AppModule(
    id: 'climate',
    label: 'Climate',
    icon: Icons.air_outlined,
    builder: (_) => const ClimatePage(),
  ),
  AppModule(
    id: 'parking',
    label: 'Parking',
    icon: Icons.local_parking_outlined,
    builder: (_) => const ParkingPage(),
  ),
  AppModule(
    id: 'media',
    label: 'Media',
    icon: Icons.music_note_outlined,
    builder: (_) => const MediaPage(),
  ),
  AppModule(
    id: 'settings',
    label: 'Settings',
    icon: Icons.settings_outlined,
    builder: (_) => const SettingsPage(),
  ),
];
