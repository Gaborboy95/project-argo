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
