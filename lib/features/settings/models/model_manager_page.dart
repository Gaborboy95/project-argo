import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/camera/parking_model_service.dart';

class ModelManagerPage extends StatefulWidget {
  const ModelManagerPage({super.key, required this.service, this.camera});
  final ParkingModelService service;
  final Map<String, dynamic>? camera;
  @override
  State<ModelManagerPage> createState() => _ModelManagerPageState();
}

class _ModelManagerPageState extends State<ModelManagerPage> {
  Timer? _timer;
  bool _pending = false;
  Map<String, dynamic> _state = {};
  String? _error;
  @override
  void initState() {
    super.initState();
    unawaited(_request('status'));
    _timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _request('status'),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _request(String action, {String? id}) async {
    if (_pending) return;
    _pending = true;
    try {
      final value = await widget.service.request(
        action,
        id: id,
        camera: widget.camera,
      );
      if (mounted) {
        setState(() {
          _state = value;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      _pending = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = _state['progress'] as Map? ?? {};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('AI & Models', style: Theme.of(context).textTheme.headlineSmall),
        const Text(
          'Depth estimates do not establish clearance. Unknown coverage stays unknown. Benchmarks measure speed, not accuracy.',
        ),
        if (_error != null) Text(_error!),
        if (progress['state'] != null)
          Text(
            '${progress['state']} • ${progress['received_bytes'] ?? 0} / ${progress['total_bytes'] ?? 0} bytes\n${progress['error'] ?? ''}',
          ),
        for (final model in (_state['models'] as List? ?? []).cast<Map>())
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${model['display_name']}${model['selected'] == true ? ' • Selected' : ''}',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  Text(
                    '${model['installed'] == true ? 'Installed' : 'Not installed'} • ${model['version']} • ${((model['size_bytes'] as num) / 1000000).toStringAsFixed(1)} MB • ${model['license']}',
                  ),
                  Text(
                    '${model['capabilities']} • ${model['output_units']}\nInput: ${model['input_lens_views']} • ${model['input']['shape']}\n${model['compatibility']} • ${model['provider']}',
                  ),
                  Text('${model['parking_accuracy']}'),
                  for (final benchmark
                      in (model['benchmarks'] as List? ?? []).cast<Map>())
                    Text(
                      '${benchmark['hardware']} • ${benchmark['provider']}\nInference median ${(benchmark['inference_p50_ms'] as num).toStringAsFixed(1)} ms • p95 ${(benchmark['inference_p95_ms'] as num).toStringAsFixed(1)} ms\nEnd-to-end ${(benchmark['end_to_end_p50_ms'] as num).toStringAsFixed(1)} ms • peak RSS ${(benchmark['peak_worker_rss_mib'] as num).toStringAsFixed(0)} MiB\nMeasured ${DateTime.fromMillisecondsSinceEpoch(((benchmark['measured_ns'] as num) / 1000000).round()).toLocal()}',
                    ),
                  Wrap(
                    spacing: 8,
                    children: [
                      if (model['installed'] != true)
                        TextButton(
                          onPressed: () =>
                              _request('download', id: model['id'] as String),
                          child: const Text('Download'),
                        ),
                      if (progress['state'] == 'downloading')
                        TextButton(
                          onPressed: () => _request('cancel'),
                          child: const Text('Cancel'),
                        ),
                      if (model['installed'] == true) ...[
                        TextButton(
                          onPressed: () =>
                              _request('select', id: model['id'] as String),
                          child: const Text('Select'),
                        ),
                        TextButton(
                          onPressed: () =>
                              _request('remove', id: model['id'] as String),
                          child: const Text('Remove'),
                        ),
                        TextButton(
                          onPressed: () async {
                            final status = await widget.service.control.command(
                              'perception',
                              {'action': 'status'},
                              true,
                            );
                            if (status['state'] == 'running') {
                              if (mounted) {
                                setState(
                                  () => _error = 'Stop parking perception before benchmarking',
                                );
                              }
                              return;
                            }
                            await _request(
                              'benchmark',
                              id: model['id'] as String,
                            );
                          },
                          child: const Text('Benchmark (parked only)'),
                        ),
                      ],
                      TextButton(
                        onPressed: () => showDialog<void>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: Text('${model['display_name']}'),
                            content: SingleChildScrollView(
                              child: SelectableText(
                                '${model['description']}\nSource: ${model['source']}\nExport: ${model['export_source']}\nLicense: ${model['license_sources']}\nSHA256: ${model['sha256']}\nMemory recommendation: ${model['memory_recommendation_mib']} MiB\n${model['parking_accuracy']}',
                              ),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('Close'),
                              ),
                            ],
                          ),
                        ),
                        child: const Text('Details'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
