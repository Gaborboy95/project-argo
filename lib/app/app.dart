import 'package:flutter/material.dart';

import '../core/settings/settings_service.dart';
import 'theme/argo_theme.dart';
import 'argo_environment.dart';
import 'shell/app_shell.dart';

class ArgoApp extends StatelessWidget {
  const ArgoApp({super.key, required this.environment});

  final ArgoEnvironment environment;

  @override
  Widget build(BuildContext context) {
    final settings = environment.services.get<SettingsService>();
    return StreamBuilder<SettingChange>(
      stream: settings.changes.where(
        (change) => change.keyId.startsWith('appearance.'),
      ),
      builder: (context, _) => MaterialApp(
        title: 'Project Argo',
        debugShowCheckedModeBanner: false,
        theme: ArgoTheme.build(settings, Brightness.light),
        darkTheme: ArgoTheme.build(settings, Brightness.dark),
        themeMode: ArgoTheme.mode(settings),
        home: AppShell(environment: environment),
      ),
    );
  }
}
