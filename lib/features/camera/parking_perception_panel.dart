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
  final _manifest = TextEditingController();
  Stopwatch _received = Stopwatch();
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
      unawaited(request({'action': 'status'}));
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _manifest.dispose();
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
          TextField(
            controller: _manifest,
            decoration: const InputDecoration(
              labelText: 'Local model manifest path',
            ),
          ),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: () =>
                    request({'action': 'load', 'manifest': _manifest.text}),
                child: const Text('Load model'),
              ),
              TextButton(
                onPressed: widget.cameraId == null
                    ? null
                    : () => request({
                        'action': 'start',
                        'camera_id': widget.cameraId,
                      }),
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
