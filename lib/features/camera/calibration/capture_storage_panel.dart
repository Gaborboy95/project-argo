import 'package:flutter/material.dart';

import '../../../core/camera/calibration_manager.dart';
import '../../../core/diagnostics/service_failure.dart';
import '../../shared/argo_components.dart';
import '../../shared/status_panel.dart';

class CaptureStoragePanel extends StatefulWidget {
  const CaptureStoragePanel({super.key, required this.manager});
  final CalibrationManager manager;
  @override
  State<CaptureStoragePanel> createState() => _StorageState();
}

class _StorageState extends State<CaptureStoragePanel> {
  Map<String, dynamic>? _state;
  bool _busy = false;
  ServiceFailure? _failure;
  String _size(Object? bytes) =>
      '${((bytes as num? ?? 0) / 1048576).toStringAsFixed(1)} MiB';
  Future<void> _run(String op, [Map<String, Object?> args = const {}]) async {
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      final state = await widget.manager.call(op, args);
      if (mounted) setState(() => _state = state);
    } catch (error) {
      if (mounted) {
        setState(
          () => _failure = ServiceFailure(
            feature: 'camera',
            operation: 'storage',
            kind: FailureKind.rejected,
            summary: 'Could not update capture storage',
            cause: '$error',
            retryable: true,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ExpansionTile(
    title: const Text('Capture storage'),
    onExpansionChanged: (open) {
      if (open && !_busy) _run('capture_storage');
    },
    children: [
      if (_busy) const LinearProgressIndicator(),
      if (_failure case final failure?)
        ArgoStatusPanel(
          status: ArgoStatus.failed,
          summary: failure.summary,
          failure: failure,
          onRetry: _busy ? null : () => _run('capture_storage'),
        ),
      if (_state case final state?) ...[
        Text(
          'Used ${_size(state['used_bytes'])} of ${_size(state['quota_bytes'])}\nProtected ${_size(state['protected_bytes'])} · Reclaimable ${_size(state['reclaimable_bytes'])}',
        ),
        const Text(
          'Recent captures are kept for one hour. Retained collections below protect their images; shared images remain protected while any collection references them.',
        ),
        for (final item in (state['collections'] as List? ?? []).cast<Map>())
          ListTile(
            title: Text(
              item['kind'] == 'sessions'
                  ? 'Board collection'
                  : item['kind'] == 'drafts'
                  ? 'Current installation draft'
                  : item['kind'] == 'profiles'
                  ? 'Lens profile'
                  : 'Saved calibration',
            ),
            subtitle: Text(
              '${item['capture_count']} captures · ${_size(item['protected_bytes'])}\n${item['created_ns'] is num ? DateTime.fromMillisecondsSinceEpoch(((item['created_ns'] as num) / 1000000).round()).toLocal() : item['protection']}',
            ),
            trailing: item['removable'] == true
                ? TextButton(
                    onPressed: _busy
                        ? null
                        : () async {
                            if (await confirmArgoAction(
                                  context,
                                  title: 'Remove unused board collection?',
                                  explanation: 'Remove this collection’s observation metadata. Active or referenced collections cannot be removed. Images used by other calibrations remain protected; unused images can be cleaned separately.',
                                  action: 'Remove collection',
                                ) &&
                                mounted) {
                              await _run('capture_storage_remove_session', {
                                'session_id': item['id'],
                              });
                            }
                          },
                    child: const Text('Remove'),
                  )
                : const Icon(Icons.lock_outline),
          ),
        TextButton(
          onPressed: _busy
              ? null
              : () async {
                  if (await confirmArgoAction(
                        context,
                        title: 'Clean unused captures?',
                        explanation: 'Remove only unreferenced captures older than one hour. Active and retained calibration data are preserved.',
                        action: 'Clean captures',
                      ) &&
                      mounted) {
                    await _run('capture_storage_clean');
                  }
                },
          child: const Text('Clean reclaimable captures'),
        ),
      ],
    ],
  );
}
