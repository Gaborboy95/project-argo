import 'package:flutter/material.dart';

import '../../shared/widgets/placeholder_page.dart';

class VehiclePage extends StatelessWidget {
  const VehiclePage({super.key});

  @override
  Widget build(BuildContext context) {
    return const PlaceholderPage(
      title: 'Vehicle',
      icon: Icons.directions_car_outlined,
      description: 'Vehicle controls and information',
    );
  }
}
