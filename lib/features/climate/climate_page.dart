import 'package:flutter/material.dart';

import '../../shared/widgets/placeholder_page.dart';

class ClimatePage extends StatelessWidget {
  const ClimatePage({super.key});

  @override
  Widget build(BuildContext context) {
    return const PlaceholderPage(
      title: 'Climate',
      icon: Icons.air_outlined,
      description: 'Climate control',
    );
  }
}
