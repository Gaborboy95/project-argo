import 'package:flutter/material.dart';

import 'argo_environment.dart';
import 'shell/app_shell.dart';

class ArgoApp extends StatelessWidget {
  const ArgoApp({super.key, required this.environment});

  final ArgoEnvironment environment;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Project Argo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
      home: AppShell(environment: environment),
    );
  }
}
