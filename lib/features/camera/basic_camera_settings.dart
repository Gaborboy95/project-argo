import 'package:flutter/material.dart';

import '../../core/camera/basic_camera_control.dart';
import '../../core/camera/camera_service.dart';
import '../../core/diagnostics/service_failure.dart';
import '../shared/argo_components.dart';
import '../shared/status_panel.dart';

class BasicCameraSettings extends StatefulWidget {
  const BasicCameraSettings({super.key, required this.control});
  final BasicCameraControl control;
  @override
  State<BasicCameraSettings> createState() => _BasicCameraSettingsState();
}

class _BasicCameraSettingsState extends State<BasicCameraSettings> {
  List<CameraMode> _modes = [];
  late BasicCameraConfiguration _value;
  bool _pending = true;
  Object? _error;
  @override
  void initState() {
    super.initState();
    _value = widget.control.configuration;
    _discover();
  }

  Future<void> _discover() async {
    setState(() {
      _pending = true;
      _error = null;
    });
    try {
      final modes = await widget.control.discoverModes();
      if (mounted) setState(() => _modes = modes);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }

  Future<void> _save() async {
    setState(() => _pending = true);
    try {
      await widget.control.configure(_value);
      if (mounted) Navigator.pop(context, true);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }

  void _change({
    CameraMode? mode,
    bool automatic = false,
    int? rotation,
    bool? mirror,
    bool? flip,
  }) => setState(
    () => _value = BasicCameraConfiguration(
      mode: automatic ? null : mode ?? _value.mode,
      rotation: rotation ?? _value.rotation,
      mirror: mirror ?? _value.mirror,
      flip: flip ?? _value.flip,
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Rear camera settings')),
    body: ArgoPage(
      title: 'Capture and orientation',
      subtitle: 'Preview pauses while capture settings are changed.',
      children: [
        if (_pending) const LinearProgressIndicator(),
        if (_error case final error?)
          ArgoStatusPanel(
            status: ArgoStatus.failed,
            summary: 'Could not configure the camera',
            failure: ServiceFailure(
              feature: 'camera',
              operation: 'configure',
              kind: FailureKind.unavailableDevice,
              summary: 'Could not configure the camera',
              cause: error,
              retryable: true,
              recovery: 'Stop any other camera capture, check the assigned device and retry.',
            ),
            onRetry: _pending ? null : _discover,
          ),
        if (!_pending && _error == null) ...[
          DropdownButtonFormField<CameraMode>(
            initialValue: _modes.contains(_value.mode) ? _value.mode : null,
            decoration: const InputDecoration(labelText: 'Capture mode'),
            hint: const Text('Automatic advertised mode'),
            items: [
              const DropdownMenuItem(
                value: null,
                child: Text('Automatic advertised mode'),
              ),
              for (final mode in _modes)
                DropdownMenuItem(value: mode, child: Text(mode.label)),
            ],
            onChanged: (mode) => _change(mode: mode, automatic: mode == null),
          ),
          if (_value.mode != null && !_modes.contains(_value.mode))
            const Text(
              'Saved mode is unavailable. Choose an advertised mode or Automatic before saving.',
            ),
          DropdownButtonFormField<int>(
            initialValue: _value.rotation,
            decoration: const InputDecoration(labelText: 'Rotation'),
            items: [
              for (final rotation in [0, 90, 180, 270])
                DropdownMenuItem(value: rotation, child: Text('$rotation°')),
            ],
            onChanged: (v) => _change(rotation: v),
          ),
          SwitchListTile(
            title: const Text('Mirror horizontally'),
            value: _value.mirror,
            onChanged: (v) => _change(mirror: v),
          ),
          SwitchListTile(
            title: const Text('Flip vertically'),
            value: _value.flip,
            onChanged: (v) => _change(flip: v),
          ),
          FilledButton(
            onPressed: _value.mode == null || _modes.contains(_value.mode)
                ? _save
                : null,
            child: const Text('Save and preview'),
          ),
        ],
      ],
    ),
  );
}

Future<void> showBasicCameraSettings(
  BuildContext context,
  CameraService service,
  BasicCameraControl control,
) async {
  await Navigator.of(context).push<bool>(
    MaterialPageRoute(builder: (_) => BasicCameraSettings(control: control)),
  );
  // The retained camera page decides whether it still owns presentation.
}
