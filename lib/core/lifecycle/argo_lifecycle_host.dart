import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import 'app_lifecycle_coordinator.dart';

/// Adapts Flutter process lifecycle signals to the generic coordinator.
final class ArgoLifecycleHost extends StatefulWidget {
  const ArgoLifecycleHost({
    super.key,
    required this.coordinator,
    required this.child,
  });

  final AppLifecycleCoordinator coordinator;
  final Widget child;

  @override
  State<ArgoLifecycleHost> createState() => ArgoLifecycleHostState();
}

final class ArgoLifecycleHostState extends State<ArgoLifecycleHost>
    with WidgetsBindingObserver {
  Future<void>? _shutdownFuture;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    await _requestShutdown();
    return AppExitResponse.exit;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      unawaited(_requestShutdown());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_requestShutdown());
    super.dispose();
  }

  Future<void> _requestShutdown() =>
      _shutdownFuture ??= _shutdownAndReportFailure();

  Future<void> _shutdownAndReportFailure() async {
    try {
      await widget.coordinator.shutdown();
    } on Object catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'Project Argo lifecycle',
          context: ErrorDescription('while shutting down application services'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
