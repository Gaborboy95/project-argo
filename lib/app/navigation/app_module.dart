import 'package:flutter/material.dart';

import '../../core/services/service_registry.dart';

typedef AppModuleBuilder = Widget Function(
  BuildContext context,
  ServiceRegistry services,
);

class AppModule {
  const AppModule({
    required this.id,
    required this.label,
    required this.icon,
    required this.builder,
  });

  final String id;
  final String label;
  final IconData icon;
  final AppModuleBuilder builder;
}
