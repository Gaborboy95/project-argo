import 'package:flutter/material.dart';

import '../../core/audio/audio_backend.dart';
import '../../core/audio/audio_service.dart';
import '../../core/diagnostics/service_failure.dart';
import '../shared/argo_components.dart';
import '../shared/status_panel.dart';

class AudioOutputSetupCard extends StatefulWidget {
  const AudioOutputSetupCard({
    super.key,
    required this.audio,
    required this.setup,
  });
  final AudioService audio;
  final AudioOutputSetup setup;
  @override
  State<AudioOutputSetupCard> createState() => _AudioOutputSetupCardState();
}

class _AudioOutputSetupCardState extends State<AudioOutputSetupCard> {
  List<AudioOutputDevice> _outputs = [];
  bool _pending = false;
  String? _confirmed;
  ServiceFailure? _failure;
  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _pending = true;
      _failure = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(
          () => _failure = ServiceFailure(
            feature: 'audio',
            operation: 'configure',
            kind: FailureKind.unavailableDevice,
            summary: 'Could not complete the output check',
            cause: error,
            retryable: true,
            recovery: 'Check the desktop audio service and reconnect the selected output.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }

  Future<void> _refresh() => _run(() async {
    final outputs = await widget.setup.discoverOutputs();
    if (mounted) setState(() => _outputs = outputs);
  });

  @override
  Widget build(BuildContext context) {
    final selected = widget.audio.current.selectedOutput;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_pending) const LinearProgressIndicator(),
        if (_failure case final failure?)
          ArgoStatusPanel(
            status: ArgoStatus.failed,
            summary: failure.summary,
            failure: failure,
            onRetry: _pending ? null : _refresh,
          ),
        if (selected != null && !_outputs.any((o) => o.id == selected))
          const Text(
            'Selected output is unavailable. Reconnect it or explicitly choose another output.',
          ),
        for (final output in _outputs)
          ArgoDeviceChoice(
            name: output.name,
            identifier: output.id,
            selected: output.id == selected,
            onSelect: _pending
                ? null
                : () => _run(() async {
                    await widget.audio.selectOutput(output.id);
                    if (mounted) setState(() => _confirmed = null);
                  }),
          ),
        Wrap(
          spacing: ArgoSpacing.gap,
          children: [
            TextButton(
              onPressed: _pending ? null : _refresh,
              child: const Text('Refresh outputs'),
            ),
            OutlinedButton(
              onPressed: _pending || _outputs.isEmpty
                  ? null
                  : () => _run(widget.setup.testOutput),
              child: const Text('Test tone · 2 seconds'),
            ),
            TextButton(
              onPressed: _pending || _outputs.isEmpty
                  ? null
                  : () => setState(() => _confirmed = selected ?? 'default'),
              child: Text(
                _confirmed == (selected ?? 'default')
                    ? 'Output confirmed'
                    : 'I heard the tone',
              ),
            ),
          ],
        ),
        const Text(
          'The quiet tone uses the current system output, volume and mute. Output selection does not raise the volume.',
        ),
      ],
    );
  }
}
