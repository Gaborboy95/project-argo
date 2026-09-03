import 'dart:async';

enum AppShutdownPhase { stopActivity, persistState, releaseResources }

typedef AppShutdownHandler = FutureOr<void> Function();
typedef AppLifecycleFailureHandler = void Function(
  AppLifecycleCleanupFailure failure,
);

final class AppLifecycleCleanupFailure {
  const AppLifecycleCleanupFailure({
    required this.registrationName,
    required this.phase,
    required this.error,
    required this.stackTrace,
    required this.isFirstFailure,
  });

  final String registrationName;
  final AppShutdownPhase phase;
  final Object error;
  final StackTrace stackTrace;
  final bool isFirstFailure;
}

/// Owns explicit cleanup registrations for normal shutdown and rollback.
final class AppLifecycleCoordinator {
  AppLifecycleCoordinator({this._onCleanupFailure});

  final AppLifecycleFailureHandler? _onCleanupFailure;
  final List<_ShutdownRegistration> _registrations = [];
  Future<void>? _shutdownFuture;
  var _nextOrder = 0;

  bool get isShutdownRequested => _shutdownFuture != null;

  AppLifecycleRegistration registerShutdown({
    required String name,
    required AppShutdownHandler shutdown,
    AppShutdownPhase phase = AppShutdownPhase.releaseResources,
  }) {
    if (_shutdownFuture != null) {
      throw StateError('Cannot register "$name" after shutdown was requested.');
    }
    if (name.trim().isEmpty) {
      throw ArgumentError.value(name, 'name', 'Must not be empty');
    }
    final registration = _ShutdownRegistration(
      name: name,
      phase: phase,
      shutdown: shutdown,
      order: _nextOrder++,
    );
    _registrations.add(registration);
    return AppLifecycleRegistration._(registration);
  }

  /// Runs application composition and rolls back every registered resource if
  /// a later startup step fails. The startup exception remains authoritative.
  Future<T> runStartup<T>(Future<T> Function() startup) async {
    try {
      return await startup();
    } on Object catch (error, stackTrace) {
      try {
        await shutdown();
      } on Object {
        // Cleanup failures were reported individually. Preserve startup error.
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> shutdown() => _shutdownFuture ??= _shutdown();

  Future<void> _shutdown() async {
    final active =
        _registrations
            .where((registration) => registration.active)
            .toList(growable: false)
          ..sort((left, right) {
            final phaseOrder = left.phase.index.compareTo(right.phase.index);
            return phaseOrder != 0
                ? phaseOrder
                : right.order.compareTo(left.order);
          });
    Object? firstError;
    StackTrace? firstStackTrace;

    for (final registration in active) {
      registration.active = false;
      try {
        await registration.shutdown();
      } on Object catch (error, stackTrace) {
        final isFirstFailure = firstError == null;
        firstError ??= error;
        firstStackTrace ??= stackTrace;
        _report(
          AppLifecycleCleanupFailure(
            registrationName: registration.name,
            phase: registration.phase,
            error: error,
            stackTrace: stackTrace,
            isFirstFailure: isFirstFailure,
          ),
        );
      }
    }

    if (firstError case final error?) {
      Error.throwWithStackTrace(error, firstStackTrace!);
    }
  }

  void _report(AppLifecycleCleanupFailure failure) {
    try {
      _onCleanupFailure?.call(failure);
    } on Object {
      // Diagnostics must not interrupt the remaining cleanup handlers.
    }
  }
}

final class AppLifecycleRegistration {
  AppLifecycleRegistration._(this._registration);

  final _ShutdownRegistration _registration;

  bool get isActive => _registration.active;

  void unregister() {
    _registration.active = false;
  }
}

final class _ShutdownRegistration {
  _ShutdownRegistration({
    required this.name,
    required this.phase,
    required this.shutdown,
    required this.order,
  });

  final String name;
  final AppShutdownPhase phase;
  final AppShutdownHandler shutdown;
  final int order;
  var active = true;
}
