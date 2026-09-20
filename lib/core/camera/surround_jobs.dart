import 'dart:async';

import 'camera_service.dart';

/// Restartable engine job polling; fitting/model execution never runs in Flutter.
final class SurroundJob {
  SurroundJob(
    this.control, {
    this.timeout = const Duration(minutes: 5),
    this.pollInterval = const Duration(milliseconds: 250),
    this.cleanupTimeout = const Duration(seconds: 2),
  }) {
    if (timeout <= Duration.zero ||
        pollInterval <= Duration.zero ||
        cleanupTimeout <= Duration.zero) {
      throw ArgumentError('Job deadlines must be positive');
    }
  }
  final SurroundCameraControl control;
  final Duration timeout, pollInterval, cleanupTimeout;
  _JobRun? _current;
  int? get id => _current?.id;
  bool get cancelled => _current?.failure is StateError;

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
    if (_current?.running == true) throw StateError('A job is already running');
    final run = _JobRun();
    _current = run; // Never inherit a previous run's ID.
    try {
      return await Future.any([
        _execute(run, worker, request, progress),
        run.stopped.future.then<Map<String, dynamic>>(
          (_) => throw run.failure!,
        ),
      ]).timeout(timeout);
    } on TimeoutException catch (error) {
      // Record the reason before best-effort cleanup; cancel must not rewrite it.
      run.stop(error);
      await _cleanup(run);
      rethrow;
    } finally {
      run.running = false;
    }
  }

  Future<Map<String, dynamic>> _execute(
    _JobRun run,
    String worker,
    Map<String, Object?> request,
    void Function(String)? progress,
  ) async {
    final started = await control.command('worker', {
      'worker': worker,
      'request': request,
    }, true);
    final jobId = started['job_id'];
    if (jobId is! int || jobId < 1)
      throw const FormatException('Invalid worker job ID');
    run.id = jobId;
    if (run.failure != null) {
      await _cleanup(run); // Late startup owns this ID, never the new run's ID.
      throw run.failure!;
    }
    while (true) {
      final state = await control.command('job_status', {'job_id': jobId});
      if (run.failure != null) throw run.failure!;
      progress?.call('${state['state']}');
      if (run.failure != null) throw run.failure!;
      switch (state['state']) {
        case 'complete':
          final result = Map<String, dynamic>.from(
            state['result'] as Map? ?? {},
          );
          if (result['ok'] == false)
            throw StateError(
              _failureMessage(state, fallback: 'Worker job failed'),
            );
          return result['result'] is Map
              ? Map<String, dynamic>.from(result['result'] as Map)
              : result;
        case 'failed':
          throw StateError(
            _failureMessage(state, fallback: 'Worker job failed'),
          );
        case 'cancelled':
          throw StateError(_failureMessage(state, fallback: 'Job cancelled'));
      }
      await Future.any([
        Future<void>.delayed(pollInterval),
        run.stopped.future,
      ]);
      if (run.failure != null) throw run.failure!;
    }
  }

  Future<void> _cleanup(_JobRun run) async {
    final jobId = run.id;
    if (jobId == null) return;
    await (run.cleanup ??= () async {
      try {
        await control
            .command('cancel', {'job_id': jobId}, true)
            .timeout(cleanupTimeout);
      } on Object {
        // Keep the original cancellation/timeout; cleanup cannot replace it.
      }
    }());
  }

  Future<void> cancel() async {
    final run = _current;
    if (run == null) return;
    run.stop(StateError('Job cancelled'));
    run.running = false;
    await _cleanup(run);
  }
}

final class _JobRun {
  int? id;
  bool running = true;
  Object? failure;
  Future<void>? cleanup;
  final stopped = Completer<void>();
  void stop(Object reason) {
    failure ??= reason;
    if (!stopped.isCompleted) stopped.complete();
  }
}
