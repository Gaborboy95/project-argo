import 'dart:async';

import 'camera_service.dart';

/// Restartable engine job polling; fitting/model execution never runs in Flutter.
final class SurroundJob {
  SurroundJob(this.control);
  final SurroundCameraControl control;
  int? id;
  bool cancelled = false;

  static String? _errorText(Object? value) {
    if (value == null) return null;
    final text = '$value'.trim();
    return text.isEmpty || text == 'null' ? null : text;
  }

  static String _failureMessage(
    Map<String, dynamic> state, {
    required String fallback,
  }) {
    final direct = _errorText(state['error']);
    if (direct != null) return direct;
    final result = state['result'];
    if (result is Map) {
      final worker = _errorText(result['error']);
      if (worker != null) return worker;
    }
    return fallback;
  }

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
    id = started['job_id'] as int;
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
          throw StateError(
            _failureMessage(state, fallback: 'Worker job failed'),
          );
        case 'cancelled':
          throw StateError(
            _failureMessage(state, fallback: 'Job cancelled'),
          );
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
