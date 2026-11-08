import 'package:flutter/material.dart';

import '../core/settings/settings_service.dart';
import 'theme/argo_theme.dart';
import 'argo_environment.dart';
import 'shell/app_shell.dart';
import 'shell/dashboard_status_bar.dart';
import 'argo_render_recovery.dart';
import '../core/audio/audio_service.dart';
import '../core/connectivity/connectivity_service.dart';
import '../core/projection/projection_service.dart';
import 'pairing_request_overlay.dart';

class ArgoApp extends StatefulWidget {
  const ArgoApp({super.key, required this.environment});

  final ArgoEnvironment environment;

  @override
  State<ArgoApp> createState() => _ArgoAppState();
}

class _ArgoAppState extends State<ArgoApp> {
  GlobalKey<NavigatorState> _navigator = GlobalKey<NavigatorState>();
  bool _recovered = false;

  void _returnHome() => setState(() {
    // An explicit recovery replaces only presentation. The composed services,
    // settings and phone session stay owned by the application lifecycle.
    _recovered = true;
    _navigator = GlobalKey<NavigatorState>();
  });

  @override
  Widget build(BuildContext context) {
    final settings = widget.environment.services.get<SettingsService>();
    return StreamBuilder<SettingChange>(
      stream: settings.changes.where(
        (change) => change.keyId.startsWith('appearance.'),
      ),
      builder: (context, _) => MaterialApp(
        title: 'Project Argo',
        navigatorKey: _navigator,
        debugShowCheckedModeBanner: false,
        theme: ArgoTheme.build(settings, Brightness.light),
        darkTheme: ArgoTheme.build(settings, Brightness.dark),
        themeMode: ArgoTheme.mode(settings),
        builder: (context, child) {
          final services = widget.environment.services;
          final connectivity = services.contains<ConnectivityService>()
              ? services.get<ConnectivityService>()
              : null;
          final frame = DashboardStatusFrame(
            connectivity: connectivity,
            projection: services.contains<ProjectionService>()
                ? services.get<ProjectionService>()
                : null,
            audio: services.contains<AudioService>()
                ? services.get<AudioService>()
                : null,
            child: child ?? const SizedBox.shrink(),
          );
          return ArgoRenderRecoveryScope(
            returnHome: _returnHome,
            child: connectivity == null
                ? frame
                : PairingRequestOverlay(service: connectivity, child: frame),
          );
        },
        home: AppShell(
          environment: widget.environment,
          showSetupOnFirstRun: !_recovered,
          initialModuleId: _recovered ? 'home' : null,
        ),
      ),
    );
  }
}
