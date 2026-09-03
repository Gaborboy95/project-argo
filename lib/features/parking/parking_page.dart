import 'package:flutter/material.dart';

import '../../shared/widgets/placeholder_page.dart';

class ParkingPage extends StatelessWidget {
  const ParkingPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const PlaceholderPage(
      title: 'Parking',
      icon: Icons.local_parking_outlined,
      description: 'Parking assistance',
    );
  }
}
