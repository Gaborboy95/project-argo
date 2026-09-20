import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/camera/camera_service.dart';
import '../../../core/camera/calibration_manager.dart';
import '../../../core/camera/surround_jobs.dart';
import '../calibration_wizard.dart';
import 'calibration_preview.dart';
import 'bench_lens_calibration_page.dart';
import 'camera_assignment_step.dart';
import 'calibration_fields.dart';
import 'lens_profile_selector.dart';
import 'mat_setup_step.dart';
import 'marker_review_view.dart';
import 'exchange_browser.dart';
import '../../shared/argo_components.dart';

class CalibrationHome extends StatefulWidget {
  const CalibrationHome({
    super.key,
    required this.service,
    required this.control,
  });
  final CameraService service;
  final SurroundCameraControl control;
  @override
  State<CalibrationHome> createState() => _HomeState();
}

class _HomeState extends State<CalibrationHome> {
  late final _manager = CalibrationManager(widget.service, widget.control);
  Map<String, dynamic>? _draft;
  String _message = '', _review = '', _revision = '';
  bool _busy = false, _continue = false;
  int _step = 0;
  Timer? _saveTimer;
  Future<void> _saveChain = Future.value();
  Map<String, dynamic> get cameras =>
      _draft!['cameras'] as Map<String, dynamic>;
  Map<String, dynamic> get observations =>
      _draft!['observations'] as Map<String, dynamic>;
  @override
  void initState() {
    super.initState();
    _run(() async {
      await widget.control.selectView('direct');
      final r = await _manager.call('draft_get');
      _draft = r['draft'] as Map<String, dynamic>?;
      _step = (_draft?['step'] as int? ?? 0).clamp(0, 6);
    });
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    if (_draft != null) _persist();
    unawaited(widget.service.start(CameraRole.rear));
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

  Future<void> _persist() {
    if (_draft == null) return Future.value();
    final snapshot = jsonDecode(jsonEncode(_draft)) as Map<String, dynamic>;
    _saveChain = _saveChain
        .catchError((Object e) {
          if (mounted) setState(() => _message = '$e');
        })
        .then((_) async {
          final result = await _manager.call('draft_save', {'draft': snapshot});
          // Apply invalidated poses only if no newer edit arrived during this save.
          if (jsonEncode(_draft) == jsonEncode(snapshot)) {
            _draft = Map<String, dynamic>.from(result['draft'] as Map);
            if (mounted) setState(() {});
          }
        });
    return _saveChain;
  }

  void _changed() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(
        _persist().catchError((Object error) {
          if (mounted) setState(() => _message = '$error');
        }),
      );
    });
  }

  Future<void> _assignments() async {
    await widget.service.refresh();
    for (final entry in widget.service.current.assignments.entries) {
      cameras.putIfAbsent(
        entry.value,
        () => <String, dynamic>{'state': 'uncalibrated'},
      );
      cameras[entry.value]['role'] = entry.key.name;
      cameras[entry.value]['capture_mode'] = _manager.mode(entry.value);
    }
    cameras.removeWhere(
      (id, _) => !widget.service.current.assignments.values.contains(id),
    );
    await _persist();
  }

  Future<void> _new() async {
    _draft =
        (await _manager.call('draft_new'))['draft'] as Map<String, dynamic>;
    _step = 0;
    _continue = true;
    await _assignments();
  }

  Future<void> _bench() async {
    await widget.control.selectView('direct');
    if (!mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => BenchLensCalibrationPage(manager: _manager),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _detect(
    String id, {
    Map<String, dynamic>? captured,
    bool manual = false,
  }) async {
    final role = cameras[id]['role'] as String;
    final shot = captured ?? await _manager.capture(id);
    final frame = shot['frame'] as Map;
    final signal = frame['signal'];
    if (signal == 'no_signal' || signal == 'missing' || signal == 'invalid') {
      throw StateError('$role has no usable signal');
    }
    final matRole = (_draft!['mat_assignments'] as Map?)?[role] ?? role;
    final mat = (_draft!['mats'] as Map)[matRole];
    if (mat == null) throw StateError('Enter $matRole mat dimensions first');
    await _persist();
    final r = await _manager.call(manual ? 'draft_manual' : 'draft_detect', {
      'camera_id': id,
      'image': shot['path'],
      'mat': mat,
      'mat_id': matRole,
    });
    _draft = Map<String, dynamic>.from(r['draft'] as Map);
    observations[id]['frame'] = frame;
    await _persist();
  }

  Future<void> _captureAll() async {
    await widget.control.selectView('direct');
    final shots = <Map<String, dynamic>>[];
    for (final e in cameras.entries) {
      try {
        final shot = await _manager.capture(e.key);
        shots.add({...shot, 'role': e.value['role']});
        final frame = shot['frame'] as Map;
        e.value['capture_mode'] = {
          ...Map<String, dynamic>.from(frame['capture_mode'] as Map),
          'orientation': frame['orientation'] ?? 0,
          'crop': frame['crop'],
        };
      } catch (e) {
        _message = 'Some views unavailable: $e';
      }
    }
    await _persist();
    final r = await _manager.call('calibration_contact_sheet', {
      'shots': shots,
    });
    await _manager.present(
      r['path'] as String,
      r['width'] as int,
      r['height'] as int,
      isCurrent: () => mounted,
    );
    _message =
        'Captured contact sheet • capture skew ${((r['capture_skew_ns'] as num? ?? 0) / 1000000).round()} ms. Vehicle and mats must remain stationary.';
  }

  Future<void> _preview() async {
    await _persist();
    final frames = <Map<String, dynamic>>[];
    for (final e in observations.entries) {
      final o = e.value as Map;
      if (o['frame'] == null) continue;
      frames.add({
        ...Map<String, dynamic>.from(o['frame'] as Map),
        'camera_id': e.key,
        'path': o['image'],
        'pixel_format': 'image',
      });
    }
    if (frames.isEmpty) {
      for (final id in cameras.keys) {
        try {
          final shot = await _manager.capture(id);
          frames.add({
            ...Map<String, dynamic>.from(shot['frame'] as Map),
            'camera_id': id,
            'path': shot['path'],
            'pixel_format': 'image',
          });
        } catch (e) {
          _message = 'Missing view: $e';
        }
      }
    }
    if (frames.isEmpty) {
      throw StateError('No camera images available for preview');
    }
    final image = await SurroundJob(widget.control).run('render', {
      'op': 'render',
      'calibration': {'vehicle': _draft!['vehicle'], 'cameras': cameras},
      'frames': frames,
      'view': 'top_down',
      'width': 640,
      'height': 480,
      'timeline': 'replay',
      'preview_candidate': true,
      'backend': 'software',
    });
    await _manager.present(
      image['output'] as String,
      image['width'] as int,
      image['height'] as int,
      isCurrent: () => mounted,
    );
    _message =
        'Coverage: ${image['coverage_fraction']} • Missing: ${image['missing_cameras']}\nUncovered regions remain unknown. Visual fit does not validate metric clearance.';
  }

  Future<void> _saved() async {
    final state = await _manager.call('list_revisions');
    if (!mounted) return;
    final revision = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Saved calibrations'),
        children: [
          for (final record in state['revisions'] as List)
            SimpleDialogOption(
              onPressed: () =>
                  Navigator.pop(context, record['revision'] as String),
              child: Text(
                '${record['revision'] == state['active'] ? 'Active • ' : ''}${DateTime.fromMillisecondsSinceEpoch(((record['created_ns'] as num) / 1000000).round()).toLocal()} • ${record['camera_count']} cameras\n${record['revision']}',
              ),
            ),
        ],
      ),
    );
    if (revision == null) return;
    _revision = revision;
    _draft =
        (await _manager.call('draft_from_revision', {
              'revision': revision,
            }))['draft']
            as Map<String, dynamic>;
    _continue = true;
    _step = 5;
    _message =
        'Selected saved calibration for preview. Active revision remains ${state['active'] ?? 'none'}.';
  }

  Future<void> _importRig() async {
    final result = await CalibrationExchange.importFile(
      context,
      _manager,
      lensProfile: false,
    );
    if (result == null || !mounted) return;
    _revision = result['revision'] as String? ?? '';
    if (result['calibration'] is Map) {
      _draft =
          (await _manager.call('draft_from_revision', {
                'revision': _revision,
              }))['draft']
              as Map<String, dynamic>;
      _continue = true;
      _step = 5;
    }
    _message = 'Imported candidate. Inspect and preview before activation; active calibration unchanged.';
  }

  Widget _button(String label, Future<void> Function() action) => TextButton(
    onPressed: _busy ? null : () => _run(action),
    child: Text(label),
  );
  List<Widget> _content() => switch (_step) {
    0 => [
      CameraAssignmentStep(
        manager: _manager,
        cameras: cameras,
        changed: _assignments,
        checkMats: () => _run(_captureAll),
      ),
    ],
    1 => [
      LensProfileSelector(
        manager: _manager,
        cameras: cameras,
        applied: (value) {
          setState(() => cameras.addAll(value));
          _changed();
        },
        bench: _bench,
      ),
    ],
    2 => [
      const Text(
        'Vehicle dimensions are retained for later calibrations. These define the footprint and rear-axle reference, not model depth accuracy.',
      ),
      for (final f in const [
        ('length_m', 'Vehicle length (m)'),
        ('body_width_m', 'Body width (m)'),
        ('mirror_width_m', 'Mirror width (m)'),
        ('wheelbase_m', 'Wheelbase (m)'),
        ('rear_overhang_m', 'Rear axle to rear bumper (m)'),
      ])
        MeasuredField(
          label: f.$2,
          value: _draft!['vehicle'][f.$1],
          changed: (v) {
            _draft!['vehicle'][f.$1] = v;
            _changed();
          },
        ),
    ],
    3 => [MatSetupStep(draft: _draft!, changed: _changed)],
    4 => [
      _button('Detect all cameras', () async {
        final captures = <String, Map<String, dynamic>>{};
        for (final id in cameras.keys) {
          try {
            captures[id] = await _manager.capture(id);
          } catch (e) {
            _message = '$id: $e';
          }
        }
        final stamps =
            captures.values
                .map((s) => (s['frame']['capture_ns'] as num).toInt())
                .toList()
              ..sort();
        if (stamps.length > 1 && stamps.last - stamps.first > 250000000) {
          throw StateError(
            'Capture skew exceeds 250 ms. Keep the car and mats stationary and retry.',
          );
        }
        for (final id in cameras.keys.toList()) {
          try {
            if (!captures.containsKey(id)) {
              throw StateError('Camera capture unavailable');
            }
            await _detect(id, captured: captures[id]);
          } catch (e) {
            (_draft!.putIfAbsent('statuses', () => <String, dynamic>{})
                    as Map)[id] =
                'Failed: $e';
          }
        }
        await _persist();
      }),
      for (final e in cameras.entries)
        ListTile(
          title: Text(
            '${e.value['role']} • ${(_draft!['statuses'] as Map?)?[e.key] ?? observations[e.key]?['status'] ?? 'Not captured'}',
          ),
          trailing: Wrap(
            children: [
              TextButton(
                onPressed: () => _run(() => _detect(e.key)),
                child: const Text('Capture / detect'),
              ),
              TextButton(
                onPressed: () => _run(() => _detect(e.key, manual: true)),
                child: const Text('Manual anchors'),
              ),
              TextButton(
                onPressed: observations[e.key] == null
                    ? null
                    : () => setState(() => _review = e.key),
                child: const Text('Review'),
              ),
              TextButton(
                onPressed: () => _run(() async {
                  await _persist();
                  _draft =
                      (await _manager.call('draft_reset_camera', {
                            'camera_id': e.key,
                          }))['draft']
                          as Map<String, dynamic>;
                  _review = '';
                }),
                child: const Text('Reset camera'),
              ),
            ],
          ),
        ),
      if (observations[_review] != null)
        MarkerReviewView(
          key: ValueKey('${_review}_${observations[_review]['source_sha256']}'),
          manager: _manager,
          observation: observations[_review] as Map<String, dynamic>,
          changed: _changed,
          redetect: () => _run(() => _detect(_review)),
        ),
      _button('Solve installed camera poses', () async {
        await _persist();
        _draft =
            (await _manager.call('draft_solve'))['draft']
                as Map<String, dynamic>;
        _message = '${_draft!['statuses']}';
      }),
    ],
    5 => [
      CalibrationPreview(service: _manager.service),
      _button('Render captured surround preview', _preview),
      _button('Show captured original views', _captureAll),
      for (final e in cameras.entries)
        _button('Recalibrate ${e.value['role']}', () async {
          _review = e.key;
          _step = 4;
        }),
    ],
    _ => [
      Text('Candidate: ${_revision.isEmpty ? 'Not saved' : _revision}'),
      _button('Save calibration', () async {
        await _persist();
        _revision =
            (await _manager.call('draft_candidate'))['revision'] as String;
        _message = 'Candidate saved; active calibration unchanged';
      }),
      _button('Save & activate', () async {
        await _persist();
        _revision =
            (await _manager.call('draft_candidate'))['revision'] as String;
        await _manager.call('activate', {'revision': _revision});
        _message = 'Active revision $_revision';
      }),
      _button('Export calibration', () async {
        if (_revision.isEmpty) throw StateError('Save a candidate first');
        final saved = await CalibrationExchange.exportFile(
          context,
          _manager,
          kind: 'rig',
          id: _revision,
        );
        if (saved) _message = 'Calibration exported to the selected folder';
      }),
      _button('Roll back', () async {
        _message = '${await _manager.call('rollback')}';
      }),
      _button('Duplicate as new candidate', () async {
        await _persist();
        _revision =
            (await _manager.call('draft_candidate'))['revision'] as String;
      }),
      _button('View saved calibrations', _saved),
      _button('Import calibration', _importRig),
      if (_revision.isNotEmpty)
        _button('Activate inspected candidate', () async {
          await _manager.call('activate', {'revision': _revision});
          _message = 'Active revision $_revision';
        }),
    ],
  };
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Calibrate 360°'),
      actions: [
        PopupMenuButton<String>(
          onSelected: (value) {
            if (value == 'bench') {
              _bench();
            } else {
              Navigator.push<void>(
                context,
                MaterialPageRoute(
                  builder: (_) => CalibrationWizard(
                    service: widget.service,
                    control: widget.control,
                    metricOnly: true,
                  ),
                ),
              );
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(
              value: 'bench',
              child: Text('Advanced: Bench lens calibration'),
            ),
            PopupMenuItem(
              value: 'metric',
              child: Text('Advanced: Metric validation / diagnostics'),
            ),
          ],
        ),
      ],
    ),
    body: Column(
      children: [
        if (_busy) const LinearProgressIndicator(),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _button('Capture storage use', () async {
                final r = await _manager.call('capture_storage');
                _message =
                    '${((r['used_bytes'] as num) / 1048576).toStringAsFixed(1)} MiB / 256 MiB • ${r['protected_count']} referenced captures';
              }),
              _button('Clean old unused calibration captures', () async {
                if (!await confirmArgoAction(
                  context,
                  title: 'Clean unused captures?',
                  explanation: 'Remove unreferenced captures older than one hour. Saved calibrations and referenced captures are preserved.',
                  action: 'Clean captures',
                )) {
                  return;
                }
                final r = await _manager.call('capture_storage_clean');
                _message =
                    'Reclaimed ${((r['reclaimed_bytes'] as num) / 1048576).toStringAsFixed(1)} MiB; referenced and recent captures kept';
              }),
              if (!_continue) ...[
                if (_draft != null)
                  _button('Continue current calibration', () async {
                    _continue = true;
                  }),
                _button('Start new', _new),
                _button('View saved calibrations', _saved),
                _button('Import calibration', _importRig),
                if (_revision.isNotEmpty)
                  _button('Activate inspected candidate', () async {
                    await _manager.call('activate', {'revision': _revision});
                    _message = 'Active revision $_revision';
                  }),
              ] else ...[
                Wrap(
                  spacing: 6,
                  children: [
                    for (var i = 0; i < 7; i++)
                      ChoiceChip(
                        label: Text(
                          const [
                            'Cameras',
                            'Lens',
                            'Vehicle',
                            'Mats',
                            'Detect & review',
                            'Preview',
                            'Save',
                          ][i],
                        ),
                        selected: _step == i,
                        onSelected: _busy
                            ? null
                            : (v) => _run(() async {
                                await widget.control.selectView('direct');
                                _step = i;
                                _draft!['step'] = i;
                                await _persist();
                              }),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                ..._content(),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(_message, maxLines: 4, overflow: TextOverflow.ellipsis),
        ),
      ],
    ),
  );
}
