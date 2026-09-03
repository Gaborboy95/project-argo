import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import 'veloce_runtime.dart';

/// Connects Veloce shutdown to Flutter without changing Argo's app shell.
final class VeloceRuntimeLifecycle extends StatefulWidget {
  const VeloceRuntimeLifecycle({
    super.key,
    required this.runtime,
    required this.child,
  });

  final VeloceRuntime runtime;
  final Widget child;

  @override
  State<VeloceRuntimeLifecycle> createState() => _VeloceRuntimeLifecycleState();
}

final class _VeloceRuntimeLifecycleState extends State<VeloceRuntimeLifecycle>
    with WidgetsBindingObserver {
  Future<void>? _shutdownFuture;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    await _shutdown();
    return AppExitResponse.exit;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      unawaited(_shutdown());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_shutdown());
    super.dispose();
  }

  Future<void> _shutdown() => _shutdownFuture ??= _shutdownRuntime();

  Future<void> _shutdownRuntime() async {
    try {
      await widget.runtime.shutdown();
    } on Object catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'Project Argo Veloce integration',
          context: ErrorDescription('while shutting down Veloce'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
