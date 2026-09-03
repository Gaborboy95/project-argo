import 'dart:async';

import 'package:flutter/widgets.dart';

import '../core/diagnostics/diagnostics_service.dart';
import 'argo_error_capture.dart';
import 'bootstrap.dart';

/// Installs process error capture, composes Argo, and mounts the widget tree.
void runArgoApplication({required Map<String, String> processEnvironment}) {
  final diagnostics = DiagnosticsService();
  ArgoErrorCapture? errorCapture;
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      errorCapture = ArgoErrorCapture.install(diagnostics);
      runApp(
        await bootstrapArgoApplication(
          processEnvironment: processEnvironment,
          diagnosticsService: diagnostics,
        ),
      );
    },
    (error, stackTrace) {
      final capture = errorCapture;
      if (capture != null) {
        capture.recordZoneError(error, stackTrace);
      } else {
        diagnostics.error(
          'dart.async',
          'Uncaught error during application startup.',
          error: error,
          stackTrace: stackTrace,
        );
      }
      Zone.current.handleUncaughtError(error, stackTrace);
    },
  );
}
