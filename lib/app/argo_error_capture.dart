import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../core/diagnostics/diagnostics_service.dart';
import 'argo_render_recovery.dart';

/// Installs the Flutter/engine portions of Argo's uncaught-error capture.
final class ArgoErrorCapture {
  ArgoErrorCapture._(
    this._diagnostics,
    this._previousFlutterHandler,
    this._previousPlatformHandler,
    this._previousErrorBuilder,
  );

  factory ArgoErrorCapture.install(DiagnosticsService diagnostics) {
    final capture = ArgoErrorCapture._(
      diagnostics,
      FlutterError.onError,
      PlatformDispatcher.instance.onError,
      ErrorWidget.builder,
    );
    FlutterError.onError = capture._handleFlutterError;
    PlatformDispatcher.instance.onError = capture._handlePlatformError;
    ErrorWidget.builder = capture._buildRenderFailure;
    return capture;
  }

  final DiagnosticsService _diagnostics;
  final FlutterExceptionHandler? _previousFlutterHandler;
  final ErrorCallback? _previousPlatformHandler;
  final ErrorWidgetBuilder _previousErrorBuilder;
  Object? _lastError;
  StackTrace? _lastStackTrace;

  void recordZoneError(Object error, StackTrace stackTrace) {
    _recordOnce(
      'dart.async',
      'Uncaught asynchronous application error.',
      error,
      stackTrace,
    );
  }

  void restore() {
    if (FlutterError.onError == _handleFlutterError) {
      FlutterError.onError = _previousFlutterHandler;
    }
    if (PlatformDispatcher.instance.onError == _handlePlatformError) {
      PlatformDispatcher.instance.onError = _previousPlatformHandler;
    }
    if (ErrorWidget.builder == _buildRenderFailure) {
      ErrorWidget.builder = _previousErrorBuilder;
    }
  }

  Widget _buildRenderFailure(FlutterErrorDetails details) =>
      const ArgoRenderFailure();

  void _handleFlutterError(FlutterErrorDetails details) {
    _recordOnce(
      'flutter.framework',
      details.exceptionAsString(),
      details.exception,
      details.stack,
    );
    final previous = _previousFlutterHandler;
    if (previous != null) {
      try {
        previous(details);
      } on Object {
        // Error presentation must not recursively fail error capture.
      }
    } else {
      FlutterError.presentError(details);
    }
  }

  bool _handlePlatformError(Object error, StackTrace stackTrace) {
    _recordOnce(
      'flutter.platform',
      'Uncaught platform-dispatcher error.',
      error,
      stackTrace,
    );
    final previous = _previousPlatformHandler;
    if (previous == null) return false;
    try {
      return previous(error, stackTrace);
    } on Object {
      return false;
    }
  }

  void _recordOnce(
    String source,
    String message,
    Object error,
    StackTrace? stackTrace,
  ) {
    if (identical(error, _lastError) &&
        identical(stackTrace, _lastStackTrace)) {
      return;
    }
    final latest = _diagnostics.latest;
    if (latest != null &&
        identical(error, latest.error) &&
        (identical(stackTrace, latest.stackTrace) ||
            stackTrace?.toString() == latest.stackTrace?.toString())) {
      return;
    }
    _lastError = error;
    _lastStackTrace = stackTrace;
    try {
      _diagnostics.error(source, message, error: error, stackTrace: stackTrace);
    } on Object {
      // Global error capture must never recursively throw.
    }
  }
}
