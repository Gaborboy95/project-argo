import 'dart:async';

import 'package:argo/core/connectivity/connectivity_service.dart';
import 'package:argo/core/lifecycle/app_lifecycle_coordinator.dart';
import 'package:argo/core/lifecycle/application_exit_service.dart';
import 'package:flutter_test/flutter_test.dart';

class Connection implements ConnectivityService {
  Connection({this.onRequest});
  final void Function()? onRequest;
  final updates = StreamController<ConnectivitySnapshot>.broadcast(sync: true);
  int operation = 0, requests = 0;
  @override
  ConnectivitySnapshot get connectivity =>
      const ConnectivitySnapshot(available: true);
  @override
  Stream<ConnectivitySnapshot> get connectivityChanges => updates.stream;
  @override
  Future<void> connectivityCommand(
    String action, {
    String target = '',
    bool accept = false,
    int prompt = 0,
  }) async {
    expect(action, 'stopAll');
    operation = prompt;
    requests++;
    onRequest?.call();
  }
}

void main() {
  test(
    'Quit completes beforeQuit before daemon stopAll and local shutdown',
    () async {
      final order = <String>[];
      final release = Completer<void>();
      final connection = Connection(onRequest: () => order.add('stopAll'));
      final service = ApplicationExitService(
        lifecycle: AppLifecycleCoordinator()
          ..registerShutdown(
            name: 'local',
            shutdown: () => order.add('local shutdown'),
          ),
        connectivity: connection,
        beforeQuit: () async {
          order.add('prepare started');
          await release.future;
          order.add('prepare finished');
        },
        exitProcess: () => order.add('exit'),
      );
      final first = service.quit(), second = service.quit();
      await Future<void>.delayed(Duration.zero);
      expect(connection.requests, 0);
      expect(order, ['prepare started']);
      release.complete();
      await Future<void>.delayed(Duration.zero);
      expect(connection.requests, 1);
      expect(order, ['prepare started', 'prepare finished', 'stopAll']);
      connection.updates.add(
        ConnectivitySnapshot(available: true, stopped: connection.operation),
      );
      await Future.wait([first, second]);
      expect(order, [
        'prepare started',
        'prepare finished',
        'stopAll',
        'local shutdown',
        'exit',
      ]);
      await connection.updates.close();
    },
  );

  test(
    'Quit waits for matching daemon cleanup and local shutdown exactly once',
    () async {
      final connection = Connection();
      final order = <String>[];
      final release = Completer<void>();
      final lifecycle = AppLifecycleCoordinator()
        ..registerShutdown(
          name: 'persist',
          shutdown: () async {
            order.add('persist');
            await release.future;
          },
        );
      final service = ApplicationExitService(
        lifecycle: lifecycle,
        connectivity: connection,
        exitProcess: () => order.add('exit'),
        onCleanExit: () async => order.add('managed stop'),
      );
      final first = service.quit(), second = service.quit();
      await Future<void>.delayed(Duration.zero);
      expect(connection.requests, 1);
      expect(order, isEmpty);
      connection.updates.add(
        ConnectivitySnapshot(
          available: true,
          stopped: connection.operation - 1,
        ),
      );
      expect(order, isEmpty);
      connection.updates.add(
        ConnectivitySnapshot(available: true, stopped: connection.operation),
      );
      await Future<void>.delayed(Duration.zero);
      expect(order, ['persist']);
      release.complete();
      await Future.wait([first, second]);
      expect(order, ['persist', 'managed stop', 'exit']);
      await connection.updates.close();
    },
  );
  test('uncertain cleanup leaves application and services open', () async {
    final connection = Connection();
    var exited = false, closed = false;
    final service = ApplicationExitService(
      lifecycle: AppLifecycleCoordinator()
        ..registerShutdown(name: 'resource', shutdown: () => closed = true),
      connectivity: connection,
      exitProcess: () => exited = true,
    );
    final pending = service.quit();
    final checked = expectLater(pending, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    connection.updates.add(
      const ConnectivitySnapshot(
        available: true,
        cleanupError: 'Firewall cleanup not confirmed',
      ),
    );
    await checked;
    expect(exited, isFalse);
    expect(closed, isFalse);
    await connection.updates.close();
  });
}
