import 'dart:async';

import 'camera_service.dart';
import 'surround_jobs.dart';

enum CalibrationCameraState {
  notCaptured('Not captured'),
  captured('Captured'),
  markersFound('Markers found'),
  needsReview('Needs review'),
  readyToSolve('Ready to solve'),
  solved('Solved'),
  failed('Failed');

  const CalibrationCameraState(this.label);
  final String label;
  static CalibrationCameraState resolve(String? status, Map? observation) {
    if (status?.startsWith('Failed') == true) return failed;
    if (status == 'Solved') return solved;
    if (status == 'Captured') return captured;
    if (observation == null) return notCaptured;
    final pending = observation['manual_required'] as List? ?? [];
    final disabled = observation['disabled'] as List? ?? [];
    if (observation['ordering_confirmed'] == true &&
        pending.every(disabled.contains)) {
      return readyToSolve;
    }
    if (status == 'Markers found') return markersFound;
    return needsReview;
  }
}

/// Engine metadata facade. Files, solving and persistent drafts stay outside Argo.
class CalibrationManager {
  CalibrationManager(this.service, this.control);
  final CameraService service;
  final SurroundCameraControl control;
  final Set<SurroundJob> _jobs = {};
  bool _closed = false;
  int _generation = 0;
  CalibrationManager fork() => CalibrationManager(service, control);

  Future<Map<String, dynamic>> call(
    String op, [
    Map<String, Object?> args = const {},
  ]) => _runJob('calibration', {'op': op, ...args});

  Future<Map<String, dynamic>> render(Map<String, Object?> args) =>
      _runJob('render', args);

  Future<Map<String, dynamic>> _runJob(
    String worker,
    Map<String, Object?> args,
  ) async {
    if (_closed) throw StateError('Calibration view closed');
    final generation = _generation;
    final job = SurroundJob(control);
    _jobs.add(job);
    try {
      final result = await job.run(worker, args);
      if (_closed || generation != _generation) {
        throw StateError('Calibration decision expired');
      }
      return result;
    } finally {
      _jobs.remove(job);
    }
  }

  Future<void> cancelJobs() async {
    _generation++;
    await Future.wait([for (final job in _jobs.toList()) job.cancel()]);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await cancelJobs();
  }

  Future<Map<String, dynamic>> capture(String id) async {
    if (_closed) throw StateError('Calibration view closed');
    final generation = _generation;
    final result = await control.command('snapshot', {'camera_id': id}, true);
    if (_closed || generation != _generation) {
      throw StateError('Calibration decision expired');
    }
    return result;
  }

  Map<String, dynamic> mode(String id) {
    final streams = service.current.details['streams'] as List? ?? [];
    final stream =
        streams.where((s) => s is Map && s['camera_id'] == id).firstOrNull
            as Map?;
    final configured = service.current.details['camera_modes'] as Map? ?? {};
    final mode = Map<String, dynamic>.from(
      stream?['mode'] as Map? ?? configured[id] as Map? ?? {},
    );
    return {
      ...mode,
      'orientation': mode['orientation'] ?? 0,
      'crop': mode['crop'],
    };
  }

  Future<void> present(
    String path,
    int width,
    int height, {
    bool Function()? isCurrent,
  }) async {
    if (_closed || (isCurrent != null && !isCurrent())) return;
    await control.selectView('direct');
    if (_closed || (isCurrent != null && !isCurrent())) return;
    await control.command('present', {
      'path': path,
      'timeline': 'replay',
      'width': width,
      'height': height,
    });
  }
}
