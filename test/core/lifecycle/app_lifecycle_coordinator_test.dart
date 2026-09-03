import 'dart:async';

import 'package:argo/core/lifecycle/app_lifecycle_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'uses phase order and reverse registration order within a phase',
    () async {
      final calls = <String>[];
      final coordinator = AppLifecycleCoordinator()
        ..registerShutdown(
          name: 'settings',
          phase: AppShutdownPhase.persistState,
          shutdown: () => calls.add('settings'),
        )
        ..registerShutdown(
          name: 'veloce-first',
          shutdown: () => calls.add('veloce-first'),
        )
        ..registerShutdown(
          name: 'veloce-second',
          shutdown: () => calls.add('veloce-second'),
        )
        ..registerShutdown(
          name: 'simulation',
          phase: AppShutdownPhase.stopActivity,
          shutdown: () => calls.add('simulation'),
        );

      await coordinator.shutdown();

      expect(calls, [
        'simulation',
        'settings',
        'veloce-second',
        'veloce-first',
      ]);
    },
  );

  test('shutdown is idempotent when requested concurrently', () async {
    final release = Completer<void>();
    var calls = 0;
    final coordinator = AppLifecycleCoordinator()
      ..registerShutdown(
        name: 'resource',
        shutdown: () async {
          calls++;
          await release.future;
        },
      );

    final first = coordinator.shutdown();
    final second = coordinator.shutdown();
    release.complete();
    await Future.wait([first, second]);
    await coordinator.shutdown();

    expect(calls, 1);
  });

  test('attempts every handler and retains the first failure', () async {
    final firstFailure = StateError('first');
    final secondFailure = StateError('second');
    final calls = <String>[];
    final failures = <AppLifecycleCleanupFailure>[];
    final coordinator = AppLifecycleCoordinator(onCleanupFailure: failures.add)
      ..registerShutdown(name: 'success', shutdown: () => calls.add('success'))
      ..registerShutdown(
        name: 'second-failure',
        shutdown: () {
          calls.add('second-failure');
          throw secondFailure;
        },
      )
      ..registerShutdown(
        name: 'first-failure',
        shutdown: () {
          calls.add('first-failure');
          throw firstFailure;
        },
      );

    await expectLater(coordinator.shutdown(), throwsA(same(firstFailure)));

    expect(calls, ['first-failure', 'second-failure', 'success']);
    expect(failures.map((failure) => failure.registrationName), [
      'first-failure',
      'second-failure',
    ]);
    expect(failures.first.isFirstFailure, isTrue);
    expect(failures.last.isFirstFailure, isFalse);
  });

  test('a failing diagnostics handler cannot interrupt cleanup', () async {
    final calls = <String>[];
    final coordinator =
        AppLifecycleCoordinator(
            onCleanupFailure: (_) => throw StateError('diagnostics failed'),
          )
          ..registerShutdown(
            name: 'still-runs',
            shutdown: () => calls.add('still-runs'),
          )
          ..registerShutdown(
            name: 'fails',
            shutdown: () {
              calls.add('fails');
              throw StateError('cleanup failed');
            },
          );

    await expectLater(coordinator.shutdown(), throwsStateError);

    expect(calls, ['fails', 'still-runs']);
  });

  test(
    'startup failure rolls back and keeps its original stack trace',
    () async {
      final startupFailure = StateError('startup failed');
      final cleanupFailure = StateError('cleanup failed');
      final calls = <String>[];
      final coordinator = AppLifecycleCoordinator();

      Object? caughtError;
      StackTrace? caughtStackTrace;
      try {
        await coordinator.runStartup<void>(() async {
          coordinator.registerShutdown(
            name: 'first-resource',
            shutdown: () => calls.add('first-resource'),
          );
          coordinator.registerShutdown(
            name: 'second-resource',
            shutdown: () {
              calls.add('second-resource');
              throw cleanupFailure;
            },
          );
          await _failStartup(startupFailure);
        });
      } on Object catch (error, stackTrace) {
        caughtError = error;
        caughtStackTrace = stackTrace;
      }

      expect(caughtError, same(startupFailure));
      expect(caughtStackTrace.toString(), contains('_failStartup'));
      expect(calls, ['second-resource', 'first-resource']);
    },
  );
}

Future<void> _failStartup(Object error) async {
  throw error;
}
