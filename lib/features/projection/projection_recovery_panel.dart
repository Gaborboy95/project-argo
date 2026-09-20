import 'package:flutter/material.dart';

import '../../core/projection/projection_recovery.dart';
import '../../core/projection/projection_service.dart';
import '../shared/status_panel.dart';

class ProjectionRecoveryPanel extends StatefulWidget {
  const ProjectionRecoveryPanel({
    super.key,
    required this.service,
    required this.decision,
  });
  final ProjectionService service;
  final ProjectionSwitchRecovery decision;
  @override
  State<ProjectionRecoveryPanel> createState() =>
      _ProjectionRecoveryPanelState();
}

class _ProjectionRecoveryPanelState extends State<ProjectionRecoveryPanel> {
  bool pending = false;
  String? error;
  Future<void> _recover(bool previous) async {
    final service = widget.service;
    if (service is! ProjectionRecovery) return;
    setState(() {
      pending = true;
      error = null;
    });
    try {
      await (service as ProjectionRecovery).recover(
        widget.decision,
        returnToPrevious: previous,
      );
    } on Object {
      if (mounted) {
        setState(
          () => error = 'Recovery is no longer available. Select the connected phone again.',
        );
      }
    } finally {
      if (mounted) setState(() => pending = false);
    }
  }

  String name(String? value) => switch (value) {
    'carPlay' => 'CarPlay',
    'androidAuto' => 'Android Auto',
    _ => 'projection',
  };
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      ArgoStatusPanel(
        status: pending ? ArgoStatus.working : ArgoStatus.failed,
        summary: 'Could not switch to ${name(widget.decision.targetName)}',
        failure: widget.decision.failure,
      ),
      if (error != null) Text(error!),
      Wrap(
        spacing: 12,
        children: [
          FilledButton(
            onPressed: pending ? null : () => _recover(false),
            child: const Text('Retry'),
          ),
          if (widget.decision.previous != null)
            OutlinedButton(
              onPressed: pending ? null : () => _recover(true),
              child: Text('Return to ${name(widget.decision.previousName)}'),
            ),
        ],
      ),
    ],
  );
}
