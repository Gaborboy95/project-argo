import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/camera/camera_service.dart';
import '../../core/camera/surround_jobs.dart';
import 'ihs_camera_surface.dart';

/// Guided physical measurements and observations. Only metadata enters Dart.
class CalibrationWizard extends StatefulWidget {
  const CalibrationWizard({
    super.key,
    required this.service,
    required this.control,
    this.metricOnly = false,
  });
  final bool metricOnly;
  final CameraService service;
  final SurroundCameraControl control;
  @override
  State<CalibrationWizard> createState() => _CalibrationWizardState();
}

class _CalibrationWizardState extends State<CalibrationWizard> {
  final _values = <String, TextEditingController>{};
  final _cameras = <String, Map<String, dynamic>>{};
  final _observations = <Map<String, dynamic>>[];
  final _targets = <Map<String, dynamic>>[];
  final _validation = <Map<String, dynamic>>[];
  final _notices = <String>[];
  late final _job = SurroundJob(widget.control);
  int _step = 0;
  CameraRole _role = CameraRole.rear;
  String? _camera, _revision, _image, _session;
  bool _busy = false, _independent = false, _frozenPreview = false;
  List<dynamic> _corners = [];
  List<double>? _pixel;
  Map<String, dynamic>? _intrinsics, _extrinsics, _metric, _captureDescriptor;
  @override
  void initState() {
    super.initState();
    if (widget.metricOnly) {
      _step = 5;
      unawaited(
        run(() async {
          final result = await solve({'op': 'inspect'});
          final rig = result['calibration'] as Map?;
          if (rig == null) {
            throw StateError(
              'Activate a visual calibration before metric validation.',
            );
          }
          final cameras = rig['cameras'] as Map;
          for (final e in cameras.entries) {
            _cameras['${e.key}'] = Map<String, dynamic>.from(e.value as Map);
          }
          _camera = widget.service.current.assignments[_role];
          final selected = _cameras[_camera];
          if (selected == null) {
            throw StateError(
              'Rear camera has no active installed calibration.',
            );
          }
          _intrinsics = Map<String, dynamic>.from(selected);
          _extrinsics = Map<String, dynamic>.from(selected);
          for (final e in (rig['vehicle'] as Map).entries) {
            field('${e.key}').text = '${e.value}';
          }
          field('mount_state').text = '${selected['mount_state']}';
          _revision = rig['revision'] as String?;
          await widget.service.start(_role);
        }),
      );
    }
  }

  TextEditingController field(String name) =>
      _values.putIfAbsent(name, TextEditingController.new);
  double number(String name, {bool positive = true}) {
    final value = double.tryParse(field(name).text);
    if (value == null || !value.isFinite || (positive && value <= 0)) {
      throw FormatException(
        'Enter ${name.replaceAll('_', ' ')} in the displayed units.',
      );
    }
    return value;
  }

  Map<String, double> get _vehicle => {
    for (final name in [
      'length_m',
      'body_width_m',
      'mirror_width_m',
      'wheelbase_m',
      'rear_overhang_m',
    ])
      name: number(name),
  };
  Map<String, Object?> get _board => {
    'columns': number('columns').toInt(),
    'rows': number('rows').toInt(),
    'square_m': number('square_m'),
  };
  Future<void> run(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _notices.clear();
    });
    try {
      await operation();
    } on Object catch (error) {
      _notices.add('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<Map<String, dynamic>> solve(Map<String, Object?> request) =>
      _job.run('calibration', request);
  Map<String, dynamic> get _captureMode {
    final streams = widget.service.current.details['streams'] as List? ?? [];
    final stream =
        streams.where((dynamic s) => s['camera_id'] == _camera).firstOrNull
            as Map?;
    final mode =
        _captureDescriptor?['capture_mode'] as Map? ?? stream?['mode'] as Map?;
    return {
      if (mode != null) ...Map<String, dynamic>.from(mode),
      'orientation': _captureDescriptor?['orientation'] ?? 0,
      'crop': _captureDescriptor?['crop'],
    };
  }

  Future<void> captureForMeasurement() async {
    if (_camera == null) throw StateError('Select a camera first.');
    final shot = await widget.control.command('snapshot', {
      'camera_id': _camera,
    }, true);
    _captureDescriptor = Map<String, dynamic>.from(shot['frame'] as Map);
    _image = shot['path'] as String;
    await widget.control.command('present', {
      'path': _image,
      'timeline': 'replay',
      'width': _captureDescriptor!['width'],
      'height': _captureDescriptor!['height'],
    });
    _frozenPreview = true;
    _corners = [];
    _pixel = null;
  }

  Map<String, dynamic> get _cameraCalibration => {
    'camera_id': _camera,
    'binding': _camera,
    'capture_mode': _captureMode,
    'mount_state': field('mount_state').text,
    'fit_points_vehicle_m': _targets.map((t) => t['point']).toList(),
    'orientation_degrees': int.tryParse(field('orientation_degrees').text) ?? 0,
    ...?_intrinsics,
    ...?_extrinsics,
    if (_metric != null) 'metric_validation': _metric,
    'state':
        _metric?['state'] ??
        (_extrinsics == null
            ? 'uncalibrated'
            : field('mount_state').text.isEmpty
            ? 'approximate_visualization'
            : 'geometrically_validated'),
  };
  void _storeCamera() {
    if (_camera != null) _cameras[_camera!] = _cameraCalibration;
  }

  @override
  void dispose() {
    for (final controller in _values.values) {
      controller.dispose();
    }
    // Jobs are restartable in the engine; closing the wizard cancels its current solve.
    if (_busy) unawaited(_job.cancel());
    unawaited(widget.service.start(_role));
    super.dispose();
  }

  Widget input(String name, String label, {String? helper}) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: field(name),
      decoration: InputDecoration(labelText: label, helperText: helper),
      keyboardType: const TextInputType.numberWithOptions(
        decimal: true,
        signed: true,
      ),
    ),
  );
  Widget action(String label, Future<void> Function() operation) => Padding(
    padding: const EdgeInsets.only(right: 8, bottom: 8),
    child: FilledButton.tonal(
      onPressed: _busy ? null : () => run(operation),
      child: Text(label),
    ),
  );
  Widget pointList(
    List<Map<String, dynamic>> points, {
    required bool validation,
  }) {
    final coordinate = validation ? 'measured_vehicle_m' : 'point';
    final xKey = validation ? 'validation_x' : 'target_x';
    final yKey = validation ? 'validation_y' : 'target_y';
    return Column(
      children: [
        for (var i = 0; i < points.length; i++)
          ListTile(
            title: Text(
              'Point ${i + 1} • ${validation ? 'validation' : 'fit'} • ${points[i]['camera_id'] ?? _camera}',
            ),
            subtitle: Text(
              'Pixel ${points[i]['pixel']} • vehicle ${points[i][coordinate]}',
            ),
            trailing: Wrap(
              children: [
                IconButton(
                  tooltip: 'Show point',
                  icon: const Icon(Icons.visibility),
                  onPressed: () => setState(
                    () => _pixel = (points[i]['pixel'] as List)
                        .map((n) => (n as num).toDouble())
                        .toList(),
                  ),
                ),
                IconButton(
                  tooltip: 'Edit point',
                  icon: const Icon(Icons.edit),
                  onPressed: () => setState(() {
                    final p = points.removeAt(i);
                    _pixel = (p['pixel'] as List)
                        .map((n) => (n as num).toDouble())
                        .toList();
                    field(xKey).text = '${p[coordinate][0]}';
                    field(yKey).text = '${p[coordinate][1]}';
                    _metric = null;
                    if (!validation) _extrinsics = null;
                    _notices.add(
                      'Edit the coordinates, then add the point again.',
                    );
                  }),
                ),
                IconButton(
                  tooltip: 'Remove point',
                  icon: const Icon(Icons.delete),
                  onPressed: () => setState(() {
                    points.removeAt(i);
                    _metric = null;
                    if (!validation) _extrinsics = null;
                  }),
                ),
              ],
            ),
          ),
        Wrap(
          children: [
            TextButton(
              onPressed: points.isEmpty
                  ? null
                  : () => setState(() {
                      points.removeLast();
                      _metric = null;
                      if (!validation) _extrinsics = null;
                    }),
              child: const Text('Undo last point'),
            ),
            TextButton(
              onPressed: () => setState(() {
                points.clear();
                _metric = null;
                if (!validation) _extrinsics = null;
              }),
              child: const Text('Clear all points'),
            ),
          ],
        ),
      ],
    );
  }

  Widget preview({bool pick = false}) {
    final camera = widget.service.current;
    final width = camera.width, height = camera.height;
    return SizedBox(
      height: 240,
      child: AspectRatio(
        aspectRatio: width != null && height != null ? width / height : 16 / 9,
        child: LayoutBuilder(
          builder: (context, constraints) => GestureDetector(
            onTapDown: pick && width != null && height != null
                ? (event) => setState(() {
                    _pixel = [
                      event.localPosition.dx / constraints.maxWidth * width,
                      event.localPosition.dy / constraints.maxHeight * height,
                    ];
                  })
                : null,
            child: Stack(
              fit: StackFit.expand,
              children: [
                const IgnorePointer(
                  child: IhsCameraSurface(
                    external: true,
                    key: ValueKey('calibration-live-view'),
                  ),
                ),
                if (width != null && height != null)
                  for (final corner in _corners)
                    Positioned(
                      left:
                          (corner[0] as num) / width * constraints.maxWidth - 2,
                      top:
                          (corner[1] as num) / height * constraints.maxHeight -
                          2,
                      child: const SizedBox(
                        width: 4,
                        height: 4,
                        child: ColoredBox(color: Colors.greenAccent),
                      ),
                    ),
                if (_pixel != null && width != null && height != null)
                  Positioned(
                    left: _pixel![0] / width * constraints.maxWidth - 10,
                    top: _pixel![1] / height * constraints.maxHeight - 10,
                    child: const Icon(Icons.add, color: Colors.amber, size: 20),
                  ),
                Positioned(
                  left: 8,
                  bottom: 8,
                  child: Text(
                    '${_frozenPreview ? 'Captured calibration preview' : camera.state.name} • ${_camera ?? 'Select camera'}',
                    style: const TextStyle(
                      color: Colors.white,
                      backgroundColor: Colors.black87,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _content() => switch (_step) {
    0 => [
      const Text(
        'Measure the installed vehicle in metres. Reference: rear axle centre on the ground; X forward, Y left, Z up. The decorative vehicle model never defines clearance.',
      ),
      input('length_m', 'Body length (m)'),
      input('body_width_m', 'Body width (m)'),
      input('mirror_width_m', 'Width including mirrors (m)'),
      input('wheelbase_m', 'Wheelbase (m)'),
      input('rear_overhang_m', 'Rear axle to rear body edge (m)'),
      action('Validate measurements', () async {
        final v = _vehicle;
        if (v['mirror_width_m']! < v['body_width_m']! ||
            v['wheelbase_m']! + v['rear_overhang_m']! >= v['length_m']!) {
          throw const FormatException(
            'Check the measured envelope and axle/body dimensions.',
          );
        }
        _notices.add(
          'Measurements accepted as inputs; geometry is not yet calibrated.',
        );
      }),
    ],
    1 => [
      const Text(
        'Assign capture adapters by stable identity. A port-bound adapter does not identify its optical camera. Save an incomplete rig if cameras are missing.',
      ),
      DropdownButton<CameraRole>(
        value: _role,
        items: [
          for (final r in CameraRole.values)
            DropdownMenuItem(value: r, child: Text(r.name)),
        ],
        onChanged: _busy ? null : (r) => setState(() => _role = r!),
      ),
      for (final device in widget.service.current.devices)
        ListTile(
          selected: _camera == device.stableId,
          title: Text(device.displayName),
          subtitle: Text(device.stableId),
          onTap: _busy
              ? null
              : () => run(() async {
                  final id = device.stableId;
                  _storeCamera();
                  _camera = id;
                  _intrinsics = null;
                  _extrinsics = null;
                  _metric = null;
                  _observations.clear();
                  _targets.clear();
                  _validation.clear();
                  await widget.service.assign(_role, id);
                  await widget.service.start(_role);
                }),
        ),
      input(
        'orientation_degrees',
        'Observed image rotation (degrees)',
        helper: '0, 90, 180 or 270; verify against the real scene',
      ),
      TextField(
        controller: field('mount_state'),
        decoration: const InputDecoration(
          labelText: 'Measured mount / ride-height reference state',
          helperText:
              'Describe the actual mount and measured ride-height condition',
        ),
      ),
      preview(),
      action('Refresh devices', widget.service.refresh),
    ],
    2 => [
      const Text(
        'Use diverse checkerboard views covering image corners, centre, tilt and distance. Print at actual size and measure the scale bar. Square dimensions are physical measurements, never guessed.',
      ),
      input('columns', 'Inner corner columns'),
      input('rows', 'Inner corner rows'),
      input('square_m', 'Measured square edge (m)'),
      TextField(
        controller: field('target_output'),
        decoration: const InputDecoration(
          labelText: 'Printable SVG output path (absolute)',
        ),
      ),
      action('Generate printable target', () async {
        final result = await solve({
          'op': 'target',
          ..._board,
          'output': field('target_output').text,
        });
        _notices.add('Target: $result');
      }),
      TextField(
        controller: field('session_id'),
        decoration: const InputDecoration(
          labelText: 'Calibration collection session ID (for resume)',
        ),
      ),
      action('Start observation session', () async {
        final session = await solve({'op': 'start_session', 'board': _board});
        _session = session['session_id'] as String;
        field('session_id').text = _session!;
        _notices.add(
          'Session $_session saved by engine. Record this ID to resume.',
        );
      }),
      action('Resume observation session', () async {
        _session = field('session_id').text;
        final session = await solve({
          'op': 'inspect_session',
          'session_id': _session,
        });
        _notices.add('Resumed $_session: $session');
      }),
      preview(),
      action('Resume live positioning', () async {
        await widget.service.start(_role);
        _frozenPreview = false;
        _corners = [];
      }),
      action('Capture observation', () async {
        if (_camera == null) throw StateError('Select a camera first.');
        final shot = await widget.control.command('snapshot', {
          'camera_id': _camera,
        }, true);
        _captureDescriptor = Map<String, dynamic>.from(shot['frame'] as Map);
        _image =
            shot['path'] as String? ??
            (shot['result'] as Map?)?['path'] as String?;
        if (_image == null) {
          throw StateError('Snapshot returned no image path.');
        }
        _session ??=
            (await solve({
                  'op': 'start_session',
                  'board': _board,
                }))['session_id']
                as String;
        field('session_id').text = _session!;
        final observed = await solve({
          'op': 'detect',
          'image': _image,
          'session_id': _session,
          'camera_id': _camera,
        });
        _corners = observed['corners'] as List? ?? [];
        _frozenPreview = true;
        await widget.control.command('present', {
          'path': _image,
          'timeline': 'replay',
          'width': widget.service.current.width,
          'height': widget.service.current.height,
        });
        if (observed['accepted'] == true) {
          _observations.add(observed);
        }
        _notices.add(
          'Accepted ${_observations.length}; blur ${observed['blur']}, coverage ${observed['coverage']}; ${observed['reason'] ?? ''}',
        );
      }),
      for (var index = 0; index < _observations.length; index++)
        ListTile(
          title: Text('Observation ${index + 1}'),
          trailing: IconButton(
            tooltip: 'Remove observation',
            icon: const Icon(Icons.delete),
            onPressed: () => run(() async {
              await solve({
                'op': 'remove_observation',
                'session_id': _session,
                'camera_id': _camera,
                'index': index,
              });
              _observations.removeAt(index);
              _intrinsics = null;
            }),
          ),
        ),
      action('Solve fisheye intrinsics', () async {
        if (_session == null) {
          throw StateError('Collect or resume an observation session first.');
        }
        _intrinsics = await solve({
          'op': 'solve_intrinsics',
          'session_id': _session,
          'camera_id': _camera,
        });
        _notices.add('Intrinsic diagnostics: ${_intrinsics!['diagnostics']}');
      }),
      TextField(
        controller: field('profile'),
        decoration: const InputDecoration(
          labelText: 'Matching local lens profile JSON file',
        ),
      ),
      action('Import lens profile', () async {
        final file = File(field('profile').text);
        if (await file.length() > 65536) {
          throw StateError('Profile exceeds 64 KiB');
        }
        final profile =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        if (profile['lens_model'] != 'opencv_fisheye' ||
            profile['K'] == null ||
            profile['D'] == null) {
          throw const FormatException(
            'Expected an OpenCV fisheye profile with K and D',
          );
        }
        _intrinsics = profile;
        _notices.add(
          'Imported profile. Confirm the same optical hardware, capture mode and crop; independent validation is still required.',
        );
      }),
    ],
    3 => [
      const Text(
        'Place surveyed targets on the reference ground. Tap each target in the live original image, then enter its measured X/Y position from the rear axle. Use at least four well-separated targets. Approximate mounting estimates do not establish calibration.',
      ),
      action('Capture target image for measurements', captureForMeasurement),
      preview(pick: true),
      input('target_x', 'Target X forward (m)'),
      input('target_y', 'Target Y left (m)'),
      action('Add ground target', () async {
        if (_pixel == null) throw StateError('Tap a target first.');
        _targets.add({
          'camera_id': _camera,
          'pixel': List<double>.from(_pixel!),
          'point': [
            number('target_x', positive: false),
            number('target_y', positive: false),
            0.0,
          ],
        });
        _pixel = null;
        _notices.add('${_targets.length} surveyed targets collected.');
      }),
      pointList(_targets, validation: false),
      action('Solve mounting pose', () async {
        if (_intrinsics == null) {
          throw StateError('Solve or import intrinsics first.');
        }
        _extrinsics = await solve({
          'op': 'solve_extrinsics',
          'intrinsics': _intrinsics,
          'image_points': _targets.map((t) => t['pixel']).toList(),
          'vehicle_points_m': _targets.map((t) => t['point']).toList(),
        });
        _notices.add('Pose diagnostics: ${_extrinsics!['diagnostics']}');
      }),
    ],
    4 => [
      const Text(
        'Review each camera before independent validation. Missing coverage remains unknown. Activate only after the candidate preview is acceptable.',
      ),
      preview(),
      Text(
        'Camera: ${_camera ?? 'unassigned'}\nIntrinsics: ${_intrinsics?['lens_model'] ?? 'missing'}\nPose: ${_extrinsics?['diagnostics'] ?? 'missing'}',
      ),
      action('Render candidate surround preview', () async {
        _storeCamera();
        final frames = <Map<String, dynamic>>[];
        for (final id in _cameras.keys) {
          try {
            final shot = await widget.control.command('snapshot', {
              'camera_id': id,
            }, true);
            frames.add({
              ...Map<String, dynamic>.from(shot['frame'] as Map),
              'camera_id': id,
              'path': shot['path'],
              'pixel_format': 'image',
            });
          } on Object {
            /* Missing camera coverage is explicit in renderer output. */
          }
        }
        if (frames.isEmpty) {
          throw StateError('Capture a connected camera before preview.');
        }
        final output =
            '${File(frames.first['path'] as String).parent.path}/argo-calibration-preview.png';
        final image = await _job.run('render', {
          'op': 'render',
          'calibration': {'vehicle': _vehicle, 'cameras': _cameras},
          'frames': frames,
          'view': 'top_down',
          'output': output,
          'width': 640,
          'height': 480,
          'timeline': 'replay',
          'preview_candidate': true,
          'backend': 'software',
        });
        await widget.control.command('present', {
          'path': image['output'],
          'timeline': 'replay',
          'width': image['width'],
          'height': image['height'],
        });
        _frozenPreview = true;
        _notices.add(
          'Captured candidate preview. Missing cameras: ${image['missing_cameras']}; coverage ${image['coverage_fraction']}',
        );
      }),
      action('Keep camera and calibrate another', () async {
        _storeCamera();
        _step = 1;
      }),
      action('Create candidate', () async {
        _storeCamera();
        final result = await solve({
          'op': 'candidate',
          'calibration': {'vehicle': _vehicle, 'cameras': _cameras},
        });
        _revision = result['revision'] as String?;
        _notices.add('Candidate $_revision; active calibration unchanged.');
      }),
    ],
    5 => [
      const Text(
        'Use independently measured points excluded from fitting, spanning the intended operating area. Metric thresholds and operating envelope must reflect real measurements. A low fitting residual does not unlock distance accuracy.',
      ),
      action('Capture target image for measurements', captureForMeasurement),
      preview(pick: true),
      input('validation_x', 'Independent X forward (m)'),
      input('validation_y', 'Independent Y left (m)'),
      input('threshold_m', 'Maximum accepted position error (m)'),
      CheckboxListTile(
        value: _independent,
        onChanged: (value) => setState(() => _independent = value!),
        title: const Text('These measurements were not used in fitting'),
      ),
      action('Add independent point', () async {
        if (_pixel == null) {
          throw StateError('Tap an independent measured point.');
        }
        _validation.add({
          'camera_id': _camera,
          'pixel': List<double>.from(_pixel!),
          'measured_vehicle_m': [
            number('validation_x', positive: false),
            number('validation_y', positive: false),
            0.0,
          ],
        });
        _pixel = null;
        _notices.add('${_validation.length} independent points collected.');
      }),
      pointList(_validation, validation: true),
      action('Validate metric geometry', () async {
        _metric = await solve({
          'op': 'validate_metric',
          'camera': _cameraCalibration,
          'observations': _validation,
          'threshold_m': number('threshold_m'),
          'independent': _independent,
        });
        _notices.add('Metric validation: $_metric');
      }),
    ],
    _ => [
      const Text(
        'Save creates an immutable candidate and then activates that exact revision. Incomplete calibration remains explicitly incomplete. Rollback selects an existing immutable revision.',
      ),
      Text(
        'Candidate: ${_revision ?? 'not saved'}; ${_cameras.length} camera(s).',
      ),
      action('Save and activate', () async {
        _storeCamera();
        final result = await solve({
          'op': 'candidate',
          'calibration': {'vehicle': _vehicle, 'cameras': _cameras},
        });
        _revision = result['revision'] as String?;
        if (_revision == null) throw StateError('Candidate was not stored.');
        await solve({'op': 'activate', 'revision': _revision});
        _notices.add('Active revision $_revision');
      }),
      TextField(
        controller: field('rollback_revision'),
        decoration: const InputDecoration(labelText: 'Existing revision ID'),
      ),
      action('Inspect revisions', () async {
        _notices.add('${await solve({'op': 'inspect'})}');
      }),
      action('Roll back', () async {
        final result = await solve({
          'op': 'rollback',
          'revision': field('rollback_revision').text,
        });
        _notices.add('Rollback: $result');
      }),
    ],
  };
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Camera calibration')),
    body: Column(
      children: [
        if (_busy) const LinearProgressIndicator(),
        Expanded(
          child: Stepper(
            currentStep: _step,
            onStepTapped: _busy ? null : (step) => setState(() => _step = step),
            onStepContinue: _busy || _step == 6
                ? null
                : () => setState(() => _step++),
            onStepCancel: _busy || _step == 0
                ? null
                : () => setState(() => _step--),
            steps: [
              for (var index = 0; index < 7; index++)
                Step(
                  title: Text(
                    const [
                      'Vehicle measurements',
                      'Assignment and orientation',
                      'Lens calibration',
                      'Ground targets and pose',
                      'Candidate preview',
                      'Independent validation',
                      'Save and rollback',
                    ][index],
                  ),
                  content: index == _step
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: _content(),
                        )
                      : const SizedBox(),
                ),
            ],
          ),
        ),
        if (_notices.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              _notices.join('\n'),
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        if (_busy)
          TextButton(
            onPressed: () => unawaited(_job.cancel()),
            child: const Text('Cancel solve'),
          ),
      ],
    ),
  );
}
