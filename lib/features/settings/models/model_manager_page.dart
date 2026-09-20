import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/camera/parking_model_service.dart';
import '../../shared/argo_components.dart';
import '../../shared/status_panel.dart';
import '../../../core/diagnostics/service_failure.dart';

class ModelManagerPage extends StatefulWidget {
  const ModelManagerPage({
    super.key,
    required this.service,
    this.camera,
    this.canBenchmark,
  });
  final ParkingModelService service;
  final bool Function()? canBenchmark;
  final Map<String, dynamic>? camera;
  @override
  State<ModelManagerPage> createState() => _ModelManagerPageState();
}

class _ModelManagerPageState extends State<ModelManagerPage> {
  Timer? _timer;
  int _foreground = 0, _revision = 0;
  bool _polling = false;
  bool get _pending => _foreground > 0;
  Future<void> _commands = Future.value();
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
    final poll = action == 'status';
    if (poll && (_polling || _pending)) return;
    if (poll) {
      _polling = true;
    } else {
      setState(() {
        _foreground++;
        _revision++;
      });
    }
    final revision = _revision;
    Future<void> execute() async {
      if (!mounted) return;
      try {
        final value = await widget.service.request(
          action,
          id: id,
          camera: widget.camera,
        );
        if (mounted && revision == _revision) {
          setState(() {
            _state = value;
            _error = null;
          });
        }
      } on Object catch (e) {
        if (mounted && revision == _revision) setState(() => _error = '$e');
      }
    }

    try {
      if (poll || action == 'cancel') {
        // Cancellation must not wait behind the operation it interrupts.
        await execute();
      } else {
        final work = _commands.then((_) => execute());
        _commands = work.catchError((Object _) {});
        await work;
      }
    } finally {
      if (poll) {
        _polling = false;
      } else if (mounted) {
        setState(() => _foreground--);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = _state['progress'] as Map? ?? {};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ArgoSection(title: 'AI & Models', children: []),
        const Text(
          'Depth estimates do not establish clearance. Unknown coverage stays unknown. Benchmarks measure speed, not accuracy.',
        ),
        if (_pending) const LinearProgressIndicator(),
        if (_error != null)
          ArgoStatusPanel(
            status: ArgoStatus.failed,
            summary: 'Could not complete the model operation',
            failure: ServiceFailure(
              feature: 'models',
              operation: 'command',
              kind: FailureKind.rejected,
              summary: 'Could not complete the model operation',
              cause: _error!,
              retryable: true,
            ),
            onRetry: () => _request('status'),
          ),
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
                      '${benchmark['hardware']} • ${benchmark['provider']}\nModel inference latency median ${(benchmark['inference_p50_ms'] as num).toStringAsFixed(1)} ms • p95 ${(benchmark['inference_p95_ms'] as num).toStringAsFixed(1)} ms\nModel pipeline latency ${(benchmark['end_to_end_p50_ms'] as num).toStringAsFixed(1)} ms • peak RSS ${(benchmark['peak_worker_rss_mib'] as num).toStringAsFixed(0)} MiB\nMeasured ${DateTime.fromMillisecondsSinceEpoch(((benchmark['measured_ns'] as num) / 1000000).round()).toLocal()}',
                    ),
                  Wrap(
                    spacing: 8,
                    children: [
                      if (model['installed'] != true)
                        TextButton(
                          onPressed: _pending
                              ? null
                              : () => _request(
                                  'download',
                                  id: model['id'] as String,
                                ),
                          child: const Text('Download'),
                        ),
                      if (progress['state'] == 'downloading')
                        TextButton(
                          onPressed: () => _request('cancel'),
                          child: const Text('Cancel'),
                        ),
                      if (model['installed'] == true) ...[
                        TextButton(
                          onPressed: _pending
                              ? null
                              : () => _request(
                                  'select',
                                  id: model['id'] as String,
                                ),
                          child: const Text('Select'),
                        ),
                        TextButton(
                          onPressed: _pending || model['selected'] == true
                              ? null
                              : () async {
                                  if (await confirmArgoAction(
                                        context,
                                        title: 'Remove model?',
                                        explanation: 'The installed model will be removed. Camera profiles and recordings are preserved.',
                                        action: 'Remove',
                                      ) &&
                                      mounted) {
                                    await _request(
                                      'remove',
                                      id: model['id'] as String,
                                    );
                                  }
                                },
                          child: const Text('Remove'),
                        ),
                        TextButton(
                          onPressed: _pending
                              ? null
                              : () async {
                                  if (widget.canBenchmark?.call() != true) {
                                    setState(
                                      () => _error = 'Close camera preview before benchmarking. Reverse presentation must remain available.',
                                    );
                                    return;
                                  }
                                  if (!await confirmArgoAction(
                                        context,
                                        title:
                                            'Run only while parked/stationary',
                                        explanation: 'Argo has not verified that the vehicle is parked. Confirm that it is safe to run a model benchmark.',
                                        action: 'Run benchmark',
                                      ) ||
                                      !mounted) {
                                    return;
                                  }
                                  if (widget.canBenchmark?.call() != true) {
                                    return;
                                  }
                                  final status = await widget.service.control
                                      .command('perception', {
                                        'action': 'status',
                                      }, true);
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
