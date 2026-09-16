import '../../core/camera/parking_model_service.dart';
import '../settings/models/model_manager_page.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/camera/camera_service.dart';

/// Results remain provider-owned estimates; unknown coverage is never 'clear'.
class ParkingPerceptionPanel extends StatefulWidget {
  const ParkingPerceptionPanel({
    super.key,
    required this.control,
    required this.cameraId,
  });
  final SurroundCameraControl control;
  final String? cameraId;
  @override
  State<ParkingPerceptionPanel> createState() => _ParkingPerceptionPanelState();
}

class _ParkingPerceptionPanelState extends State<ParkingPerceptionPanel> {
  Timer? _timer;
  bool _pending = false;
  Map<String, dynamic> _status = {};
  late final _models = ParkingModelService(widget.control);
  String _selected = 'No parking-perception model installed';
  Stopwatch _received = Stopwatch();
  @override
  void initState() {
    super.initState();
    unawaited(
      _models.request('status').then((s) {
        if (mounted) {
          setState(
            () => _selected =
                s['selected'] as String? ??
                'No parking-perception model installed',
          );
        }
      }),
    );
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
      unawaited(request({'action': 'status'}));
    });
  }

  @override
  void dispose() {
    _timer?.cancel();

    super.dispose();
  }

  Future<void> request(Map<String, Object?> args) async {
    if (_pending) return;
    _pending = true;
    try {
      final status = await widget.control.command('perception', args, true);
      if (mounted) {
        _received = Stopwatch()..start();
        setState(() => _status = status);
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _status = {'state': 'unavailable', 'error': '$error'});
      }
    } finally {
      _pending = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _status['result'] as Map?;
    final validity = result?['validity'] as String?;
    final ageNs =
        (result?['age_ns'] as num? ?? 0) + _received.elapsedMicroseconds * 1000;
    final expiry = result?['expires_after_ns'] as num?;
    final stale =
        (expiry == null || ageNs > expiry) ||
        validity == null ||
        validity.contains('stale') ||
        validity == 'unavailable';
    final units = result?['units'];
    return Material(
      color: Theme.of(context).colorScheme.surface.withValues(alpha: .94),
      borderRadius: BorderRadius.circular(12),
      child: ExpansionTile(
        title: Text('Parking perception • ${_status['state'] ?? 'checking'}'),
        subtitle: Text(
          stale
              ? 'Estimates unavailable; unobserved regions remain unknown'
              : '${units ?? 'unknown units'} • $validity • sequence ${result?['source_sequence']}',
        ),
        childrenPadding: const EdgeInsets.all(12),
        children: [
          if (_status['error'] != null) Text('${_status['error']}'),
          for (final item
              in (_status['external_results'] as Map? ?? {}).entries)
            ListTile(
              title: Text('${item.key} • ${item.value['kind']}'),
              subtitle: Text(
                '${((item.value['age_ns'] as num? ?? 0) + _received.elapsedMicroseconds * 1000) > (item.value['expires_after_ns'] as num? ?? 0) ? 'stale' : item.value['validity']} • ${item.value['units']} • ${item.value['spatial_region']}\nUncertainty: ${item.value['uncertainty']}',
              ),
            ),

          if (result != null)
            Text(
              'Input age: ${result['age_ns'] == null ? 'unknown' : '${(ageNs / 1000000).round()} ms'}\nCalibration: ${result['calibration_revision'] ?? 'unknown'}\nModel: ${result['model_revision'] ?? 'unknown'}\nCoverage: ${result['spatial_region'] ?? 'unspecified'}\nUncertainty: ${result['uncertainty'] ?? 'not calibrated'}',
            ),
          if ('$units'.contains('relative'))
            const Text(
              'Relative depth has no metre scale. No numerical vehicle clearance is claimed.',
            ),
          const Text(
            'Absence of detections does not establish clearance. Ground geometry and model metric accuracy require independent validation.',
          ),
          Text('Selected model: $_selected'),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: () async {
                  final camera = await _models.camera(widget.cameraId);
                  if (!context.mounted) return;
                  await Navigator.push<void>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => Scaffold(
                        appBar: AppBar(title: const Text('AI & Models')),
                        body: SingleChildScrollView(
                          padding: const EdgeInsets.all(16),
                          child: ModelManagerPage(
                            service: _models,
                            camera: camera,
                          ),
                        ),
                      ),
                    ),
                  );
                  final state = await _models.request('status');
                  if (mounted) {
                    setState(
                      () => _selected =
                          state['selected'] as String? ??
                          'No parking-perception model installed',
                    );
                  }
                },
                child: const Text('Manage models'),
              ),
              TextButton(
                onPressed: widget.cameraId == null
                    ? null
                    : () async {
                        try {
                          await _models.start(widget.cameraId!);
                        } catch (e) {
                          if (mounted) {
                            setState(
                              () => _status = {
                                'state': 'Incompatible',
                                'error': '$e',
                              },
                            );
                          }
                        }
                      },
                child: const Text('Start parking perception'),
              ),
              TextButton(
                onPressed: () => request({'action': 'stop'}),
                child: const Text('Stop perception'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
