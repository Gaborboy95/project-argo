import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/camera/basic_camera_control.dart';
import '../../core/camera/camera_presentation_policy.dart';
import '../../core/camera/camera_service.dart';
import '../../core/diagnostics/service_failure.dart';
import '../camera/camera_page.dart';
import '../shared/argo_components.dart';
import '../shared/status_panel.dart';

/// Preview lives only for this setup step. Reverse takes ownership in AppShell;
/// disposing this page must never stop that replacement presentation.
class SetupCamera extends StatefulWidget {
  const SetupCamera({super.key, required this.camera, this.presentation});
  final CameraService camera;
  final CameraPresentationService? presentation;
  @override
  State<SetupCamera> createState() => _SetupCameraState();
}

class _SetupCameraState extends State<SetupCamera> {
  bool _preview = false, _pending = false;
  ServiceFailure? _failure;
  bool get _automatic => widget.presentation?.current != null;
  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _pending = true;
      _failure = null;
    });
    try {
      if (_automatic) {
        throw StateError(
          'Automatic camera presentation currently owns capture.',
        );
      }
      await action();
    } catch (error) {
      if (mounted) {
        setState(
          () => _failure = ServiceFailure(
            feature: 'camera',
            operation: 'configure',
            kind: FailureKind.unavailableDevice,
            summary: 'Could not complete the camera check',
            cause: error,
            retryable: true,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }

  @override
  void dispose() {
    if (_preview && !_automatic) {
      // The service serializes stop with any following reverse start. Never
      // issue a late stop after waiting for another operation.
      unawaited(widget.camera.stop().catchError((Object _) {}));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.camera is! BasicCameraControl) {
      return const Text(
        'The optional camera integration is installed. Configure it from Camera, or set it up later. Its calibration and recordings are preserved.',
      );
    }
    return StreamBuilder<CameraSnapshot>(
      stream: widget.camera.changes,
      initialData: widget.camera.current,
      builder: (context, update) {
        final snapshot = update.requireData;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Choose the rear camera, preview it, then use Capture and orientation to check rotation and mirroring. Test while safely parked.',
            ),
            if (_pending) const LinearProgressIndicator(),
            if (_failure case final failure?)
              ArgoStatusPanel(
                status: ArgoStatus.failed,
                summary: failure.summary,
                failure: failure,
                onRetry: _pending ? null : () => _run(widget.camera.refresh),
              ),
            TextButton(
              onPressed: _pending || _preview
                  ? null
                  : () => _run(widget.camera.refresh),
              child: const Text('Discover cameras'),
            ),
            if (!_preview)
              for (final device in snapshot.devices)
                ArgoDeviceChoice(
                  name: device.displayName,
                  identifier: device.stableId,
                  selected:
                      snapshot.assignments[CameraRole.rear] == device.stableId,
                  onSelect: _pending
                      ? null
                      : () => _run(
                          () => widget.camera.assign(
                            CameraRole.rear,
                            device.stableId,
                          ),
                        ),
                ),
            if (!_preview)
              FilledButton(
                onPressed: _pending || !snapshot.rearUsable
                    ? null
                    : () => _run(() async {
                        // Mark ownership before awaiting so disposal can queue cleanup.
                        setState(() => _preview = true);
                        await widget.camera.start(CameraRole.rear);
                      }),
                child: const Text('Preview rear camera'),
              ),
            if (_preview) ...[
              SizedBox(
                height: 360,
                child: CameraActivityScope(
                  active: true,
                  onManualSelection: () => !_automatic,
                  child: CameraPage(service: widget.camera),
                ),
              ),
              TextButton(
                onPressed: _pending
                    ? null
                    : () => _run(() async {
                        await widget.camera.stop();
                        if (mounted) setState(() => _preview = false);
                      }),
                child: const Text('Stop preview'),
              ),
              const Text(
                'Confirm that left/right and the horizon match the real scene before continuing.',
              ),
            ],
          ],
        );
      },
    );
  }
}
