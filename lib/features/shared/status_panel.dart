import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/diagnostics/service_failure.dart';

enum ArgoStatus {
  ready,
  working,
  degraded,
  offline,
  failed,
  notInstalled,
  needsSetup,
}

class ArgoStatusPanel extends StatelessWidget {
  const ArgoStatusPanel({
    super.key,
    required this.status,
    required this.summary,
    this.failure,
    this.onRetry,
  });
  final ArgoStatus status;
  final String summary;
  final ServiceFailure? failure;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (status == ArgoStatus.working) const LinearProgressIndicator(),
          Text(summary, style: Theme.of(context).textTheme.titleMedium),
          if (failure?.recovery case final recovery?) Text(recovery),
          if (onRetry != null)
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          if (failure case final error?)
            ExpansionTile(
              title: const Text('Details'),
              children: [
                SelectableText(error.detail),
                TextButton.icon(
                  onPressed: () => Clipboard.setData(
                    ClipboardData(text: error.copyDiagnostics),
                  ),
                  icon: const Icon(Icons.copy),
                  label: const Text(
                    'Copy diagnostics (private content omitted)',
                  ),
                ),
              ],
            ),
        ],
      ),
    ),
  );
}

/// Keep the complete local cause available without making technical text the
/// primary message. Copy uses ServiceFailure's redacted export policy.
Future<void> showArgoFailure(
  BuildContext context,
  ServiceFailure failure, {
  Future<void> Function()? onRetry,
}) async {
  final retry = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: const Text('Operation could not finish'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: ArgoStatusPanel(
            status: ArgoStatus.failed,
            summary: failure.summary,
            failure: failure,
            onRetry: onRetry == null ? null : () => Navigator.pop(dialog, true),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog, false),
          child: const Text('Close'),
        ),
      ],
    ),
  );
  if (retry == true && context.mounted) await onRetry?.call();
}
