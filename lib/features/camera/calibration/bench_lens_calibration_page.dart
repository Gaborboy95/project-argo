import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/camera/calibration_manager.dart';
import '../../../core/camera/camera_service.dart';
import '../ihs_camera_surface.dart';
import 'calibration_fields.dart';

class BenchLensCalibrationPage extends StatefulWidget {
  const BenchLensCalibrationPage({super.key, required this.manager});
  final CalibrationManager manager;
  @override
  State<BenchLensCalibrationPage> createState() => _BenchState();
}

class _BenchState extends State<BenchLensCalibrationPage> {
  Map<String, dynamic>? _bench;
  String _model = 'opencv_omnidir', _name = '', _message = '';
  CameraRole _role = CameraRole.rear;
  String? _cameraId;
  double? _cols, _rows, _square;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _run(() async {
      final r = await widget.manager.call('bench_get');
      _bench = r['bench'] as Map<String, dynamic>?;
      if (_bench != null) {
        final assigned = widget.manager.service.current.assignments.entries
            .where((e) => e.value == _bench!['camera_id'])
            .firstOrNull;
        if (assigned != null) _role = assigned.key;
        _cameraId = _bench!['camera_id'] as String;
      }
    });
  }

  @override
  void dispose() {
    unawaited(widget.manager.service.start(_role));
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      _message = '$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _op(String op, [Map<String, Object?> args = const {}]) async {
    final r = await widget.manager.call(op, args);
    if (r['bench'] != null) {
      _bench = Map<String, dynamic>.from(r['bench'] as Map);
    }
    if (r['profile'] != null) _message = 'Lens profile saved';
  }

  @override
  Widget build(BuildContext context) {
    final observations = (_bench?['observations'] as List? ?? []).cast<Map>();
    final cells = (_bench?['coverage_cells'] as List? ?? [])
        .map((e) => '$e')
        .toSet();
    return Scaffold(
      appBar: AppBar(title: const Text('Bench lens calibration')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Keep the camera fixed. Move and tilt the board around the camera’s field of view. Capture the edges as well as the centre.',
          ),
          if (_busy) const LinearProgressIndicator(),
          Text(_message),
          if (_bench == null) ...[
            DropdownButton<String>(
              value: _cameraId,
              hint: const Text('Choose bench / spare camera'),
              isExpanded: true,
              items: [
                for (final device in widget.manager.service.current.devices)
                  DropdownMenuItem(
                    value: device.stableId,
                    child: Text(device.displayName),
                  ),
              ],
              onChanged: (id) => setState(() => _cameraId = id),
            ),
            DropdownButton<String>(
              value: _model,
              items: const [
                DropdownMenuItem(
                  value: 'opencv_omnidir',
                  child: Text('Mei omnidirectional (>180° capable)'),
                ),
                DropdownMenuItem(
                  value: 'opencv_fisheye',
                  child: Text('Legacy OpenCV fisheye'),
                ),
              ],
              onChanged: (v) => setState(() => _model = v!),
            ),
            MeasuredField(
              label: 'Inner corners per row',
              value: _cols,
              changed: (v) => _cols = v,
            ),
            MeasuredField(
              label: 'Inner corner rows',
              value: _rows,
              changed: (v) => _rows = v,
            ),
            MeasuredField(
              label: 'Measured square side (m)',
              value: _square,
              changed: (v) => _square = v,
            ),
            FilledButton(
              onPressed: () => _run(() async {
                final id = _cameraId;
                if (id == null ||
                    _cols == null ||
                    _rows == null ||
                    _square == null) {
                  throw StateError(
                    'Select an assigned camera and enter board dimensions',
                  );
                }
                await widget.manager.control.command('preview_camera', {
                  'camera_id': id,
                });
                await widget.manager.service.refresh();
                await _op('bench_start', {
                  'camera_id': id,
                  'board': {
                    'columns': _cols!.toInt(),
                    'rows': _rows!.toInt(),
                    'square_m': _square,
                  },
                  'lens_model': _model,
                  'capture_mode': widget.manager.mode(id),
                });
              }),
              child: const Text('Start board collection'),
            ),
          ] else ...[
            Text(
              'Camera: ${_bench!['camera_id']} • ${_bench!['lens_model']}\n${observations.length} accepted observations',
            ),
            SizedBox(
              height: 280,
              child: IhsCameraSurface(external: true, role: _role),
            ),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                          final shot = await widget.manager.capture(
                            _bench!['camera_id'] as String,
                          );
                          await _op('bench_capture', {'image': shot['path']});
                          _message = '${_bench!['last_detection']}';
                        }),
                  child: const Text('Capture observation'),
                ),
                TextButton(
                  onPressed: () => _run(
                    () => widget.manager.control
                        .command('preview_camera', {
                          'camera_id': _bench!['camera_id'],
                        })
                        .then((_) {}),
                  ),
                  child: const Text('Live preview / retry'),
                ),
                TextButton(
                  onPressed: observations.isEmpty
                      ? null
                      : () => _run(
                          () => _op('bench_remove', {
                            'index': observations.length - 1,
                          }),
                        ),
                  child: const Text('Undo last'),
                ),
                TextButton(
                  onPressed: () => _run(() async {
                    for (var i = observations.length - 1; i >= 0; i--) {
                      await _op('bench_remove', {'index': i});
                    }
                  }),
                  child: const Text('Clear observations'),
                ),
              ],
            ),
            const Text('Sample coverage (12 regions)'),
            for (var y = 0; y < 3; y++)
              Row(
                children: [
                  for (var x = 0; x < 4; x++)
                    Expanded(
                      child: Container(
                        height: 24,
                        margin: const EdgeInsets.all(2),
                        color: cells.contains('[$x, $y]')
                            ? Colors.green
                            : Colors.grey,
                      ),
                    ),
                ],
              ),
            for (var i = 0; i < observations.length; i++)
              ListTile(
                title: Text(
                  'Observation ${i + 1} • area ${((observations[i]['coverage'] as num? ?? 0) * 100).round()}%',
                ),
                trailing: Wrap(
                  children: [
                    IconButton(
                      tooltip: 'View observation',
                      icon: const Icon(Icons.visibility),
                      onPressed: () => _run(
                        () => widget.manager.present(
                          observations[i]['image'] as String,
                          observations[i]['image_size'][0] as int,
                          observations[i]['image_size'][1] as int,
                          isCurrent: () => mounted,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Remove observation',
                      icon: const Icon(Icons.delete),
                      onPressed: () =>
                          _run(() => _op('bench_remove', {'index': i})),
                    ),
                  ],
                ),
              ),
            FilledButton(
              onPressed: _busy ? null : () => _run(() => _op('bench_solve')),
              child: const Text('Solve lens'),
            ),
            if (_bench!['solution'] != null) ...[
              Text('Diagnostics: ${_bench!['solution']['diagnostics']}'),
              TextField(
                decoration: const InputDecoration(
                  labelText: 'Lens profile name',
                ),
                onChanged: (s) => _name = s,
              ),
              FilledButton(
                onPressed: () => _run(() => _op('bench_save', {'name': _name})),
                child: const Text('Save as lens profile'),
              ),
            ],
            TextButton(
              onPressed: () => setState(() => _bench = null),
              child: const Text('Start new bench calibration'),
            ),
          ],
        ],
      ),
    );
  }
}
