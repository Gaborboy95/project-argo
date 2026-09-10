import 'dart:async';

import '../connectivity/connectivity_service.dart';
import 'app_lifecycle_coordinator.dart';

/// Explicit exit is acknowledged only after the daemon finishes owned cleanup.
final class ApplicationExitService {
  ApplicationExitService({
    required this.lifecycle,
    required this.exitProcess,
    this.connectivity,
    this.onCleanExit,
  });
  final AppLifecycleCoordinator lifecycle;
  final ConnectivityService? connectivity;
  final void Function() exitProcess;
  final Future<void> Function()? onCleanExit;
  Future<void>? _pending;
  Future<void> quit() =>
      _pending ??= _quit().whenComplete(() => _pending = null);
  Future<void> _quit() async {
    final service = connectivity;
    if (service != null &&
        (service.connectivity.available ||
            service.connectivity.daemonConnected)) {
      final id = DateTime.now().microsecondsSinceEpoch;
      final completed = Completer<void>();
      final subscription = service.connectivityChanges.listen((s) {
        if (completed.isCompleted) return;
        if (s.stopped == id) {
          completed.complete();
        } else if (s.cleanupError.isNotEmpty) {
          completed.completeError(StateError(s.cleanupError));
        } else if (!s.available && !s.daemonConnected) {
          completed.completeError(
            StateError('Daemon connection lost before cleanup confirmation'),
          );
        }
      });
      try {
        await service.connectivityCommand('stopAll', prompt: id);
        await completed.future.timeout(
          const Duration(seconds: 30),
          onTimeout: () => throw TimeoutException(
            'Cleanup is not yet confirmed. Argo remains open; check daemon cleanup before retrying Quit.',
          ),
        );
      } finally {
        await subscription.cancel();
      }
    }
    await lifecycle.shutdown();
    await onCleanExit?.call();
    exitProcess();
  }
}
