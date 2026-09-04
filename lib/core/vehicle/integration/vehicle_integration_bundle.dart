import 'dart:io';

import '../vehicle_profile.dart';

/// One validated external vehicle integration and its contained plugin root.
final class VehicleIntegrationBundle {
  const VehicleIntegrationBundle({
    required this.profile,
    required this.rootDirectory,
    required this.velocePluginDirectory,
  });

  final VehicleProfile profile;
  final Directory rootDirectory;
  final Directory velocePluginDirectory;
}
