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
    final control = WorkerControl(
      {'ok': false, 'error': 'underconstrained fisheye observations'},
      state: 'failed',
    );
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
  test('top-level daemon error takes precedence over nested worker error', () async {
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
  });
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
