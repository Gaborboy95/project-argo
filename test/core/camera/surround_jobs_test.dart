import 'dart:async';

import 'package:argo/core/camera/camera_service.dart';
import 'package:argo/core/camera/surround_jobs.dart';
import 'package:flutter_test/flutter_test.dart';

class WorkerControl implements SurroundCameraControl {
  WorkerControl(this.result, {this.state = 'complete', this.error});
  final Map<String, dynamic> result;
  final String state;
  final String? error;
  final operations = <String>[];
  @override
  Future<Map<String, dynamic>> command(
    String op, [
    Map<String, Object?> args = const {},
    bool admin = false,
  ]) async {
    operations.add(op);
    if (op == 'worker') {
      expect(admin, isTrue);
      return {'job_id': 1};
    }
    if (op == 'job_status') {
      return {'state': state, 'result': result, 'error': error};
    }
    return {};
  }

  @override
  Future<void> selectView(
    String mode, {
    String? group,
    int? width,
    int? height,
  }) async {}
}

void main() {
  test(
    'cancelling a pending status cannot return a successful late result',
    () async {
      final control = DelayedControl();
      final job = SurroundJob(control);
      final result = job.run('calibration', {});
      final outcome = expectLater(result, throwsStateError);
      await control.polled.future;
      await job.cancel();
      control.status.complete({
        'state': 'complete',
        'result': {'ok': true},
      });
      await outcome;
    },
  );

  test('a new run never cancels the previous job ID while starting', () async {
    final control = DelayedControl();
    final job = SurroundJob(control);
    final first = job.run('calibration', {});
    await control.polled.future;
    control.status.complete({
      'state': 'complete',
      'result': {'ok': true},
    });
    await first;
    control.nextStart = Completer<Map<String, dynamic>>();
    final second = job.run('calibration', {});
    final outcome = expectLater(second, throwsStateError);
    await job.cancel();
    expect(control.cancelled, isNot(contains(1)));
    control.nextStart!.complete({'job_id': 2});
    await outcome;
    await Future<void>.delayed(Duration.zero);
    expect(control.cancelled, contains(2));
  });

  test(
    'timeout preserves its reason when cancellation cleanup fails',
    () async {
      final control = DelayedControl()..cleanupFails = true;
      final job = SurroundJob(
        control,
        timeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        job.run('calibration', {}),
        throwsA(isA<TimeoutException>()),
      );
      expect(job.cancelled, isFalse);
      expect(control.cancelled, [1]);
      control.status.complete({
        'state': 'complete',
        'result': {'ok': true},
      });
      await Future<void>.delayed(Duration.zero);
    },
  );

  test('timeout includes stalled startup and late ID is cleaned up', () async {
    final control = DelayedControl()
      ..nextStart = Completer<Map<String, dynamic>>();
    final job = SurroundJob(control, timeout: const Duration(milliseconds: 20));
    await expectLater(
      job.run('calibration', {}),
      throwsA(isA<TimeoutException>()),
    );
    expect(job.id, isNull);
    control.nextStart!.complete({'job_id': 9});
    await Future<void>.delayed(Duration.zero);
    expect(control.cancelled, [9]);
  });

  test(
    'overlapping runs receive explicit busy without starting another worker',
    () async {
      final control = DelayedControl();
      final job = SurroundJob(control);
      final first = job.run('calibration', {});
      final outcome = expectLater(first, throwsStateError);
      await control.polled.future;
      await expectLater(job.run('calibration', {}), throwsStateError);
      await job.cancel();
      await outcome;
      control.status.complete({'state': 'complete'});
    },
  );

  test(
    'solver errors remain failures and candidate activation is explicit',
    () async {
      final control = WorkerControl({
        'ok': false,
        'error': 'underconstrained fisheye observations',
      });
      await expectLater(
        SurroundJob(control).run('calibration', {'op': 'solve_intrinsics'}),
        throwsStateError,
      );
      expect(control.operations, isNot(contains('activate')));
    },
  );
  test('failed daemon job preserves nested worker error', () async {
    final control = WorkerControl({
      'ok': false,
      'error': 'underconstrained fisheye observations',
    }, state: 'failed');
    await expectLater(
      SurroundJob(control).run('calibration', {'op': 'solve_intrinsics'}),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'underconstrained fisheye observations',
        ),
      ),
    );
  });
  test(
    'top-level daemon error takes precedence over nested worker error',
    () async {
      final control = WorkerControl(
        {'ok': false, 'error': 'worker detail'},
        state: 'failed',
        error: 'worker exceeded 120 seconds',
      );
      await expectLater(
        SurroundJob(control).run('calibration', {'op': 'solve_intrinsics'}),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'worker exceeded 120 seconds',
          ),
        ),
      );
    },
  );
  test(
    'successful job exposes solver result; cancellation uses owning job',
    () async {
      final control = WorkerControl({
        'ok': true,
        'result': {'revision': 'candidate-1', 'active': false},
      });
      final job = SurroundJob(control);
      final result = await job.run('calibration', {'op': 'candidate'});
      expect(result['active'], isFalse);
      await job.cancel();
      expect(control.operations.last, 'cancel');
    },
  );
}

class DelayedControl extends WorkerControl {
  DelayedControl() : super({});
  final polled = Completer<void>();
  final status = Completer<Map<String, dynamic>>();
  Completer<Map<String, dynamic>>? nextStart;
  final cancelled = <int>[];
  bool cleanupFails = false;
  @override
  Future<Map<String, dynamic>> command(
    String op, [
    Map<String, Object?> args = const {},
    bool admin = false,
  ]) async {
    if (op == 'worker') return nextStart?.future ?? Future.value({'job_id': 1});
    if (op == 'job_status') {
      if (!polled.isCompleted) polled.complete();
      return status.future;
    }
    if (op == 'cancel') {
      cancelled.add(args['job_id'] as int);
      if (cleanupFails) throw StateError('cleanup failed');
    }
    return {};
  }
}
