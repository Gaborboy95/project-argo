import 'dart:async';

import 'camera_service.dart';

/// Restartable engine job polling; fitting/model execution never runs in Flutter.
final class SurroundJob {
  SurroundJob(this.control);
  final SurroundCameraControl control;
  String? id;
  bool cancelled = false;
  Future<Map<String, dynamic>> run(
    String worker,
    Map<String, Object?> request, {
    void Function(String)? progress,
  }) async {
    cancelled = false;
    final started = await control.command('worker', {
      'worker': worker,
      'request': request,
    }, true);
    id = '${started['job_id']}';
    final deadline = Stopwatch()..start();
    while (!cancelled && deadline.elapsed < const Duration(minutes: 5)) {
      final state = await control.command('job_status', {'job_id': id});
      progress?.call('${state['state']}');
      switch (state['state']) {
        case 'complete':
          final result = Map<String, dynamic>.from(
            state['result'] as Map? ?? {},
          );
          if (result['ok'] == false) throw StateError('${result['error']}');
          return result['result'] is Map
              ? Map<String, dynamic>.from(result['result'] as Map)
              : result;
        case 'failed':
        case 'cancelled':
          throw StateError('${state['error'] ?? state['state']}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    await cancel();
    throw StateError(cancelled ? 'Job cancelled' : 'Calibration job timed out');
  }

  Future<void> cancel() async {
    cancelled = true;
    if (id != null) await control.command('cancel', {'job_id': id}, true);
  }
}
