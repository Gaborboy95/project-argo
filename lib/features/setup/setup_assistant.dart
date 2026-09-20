import 'package:flutter/material.dart';

import '../../core/audio/audio_service.dart';
import '../../core/camera/camera_service.dart';
import '../../core/connectivity/connectivity_service.dart';
import '../../core/settings/app_setting_keys.dart';
import '../../core/settings/settings_service.dart';
import '../camera/camera_page.dart';
import '../calls/calls_page.dart';
import '../settings/audio_settings_card.dart';
import '../settings/appearance_settings_card.dart';
import '../settings/connectivity_settings_card.dart';
import '../shared/argo_components.dart';

class SetupAssistant extends StatefulWidget {
  const SetupAssistant({
    super.key,
    required this.settings,
    required this.audio,
    this.camera,
    this.connectivity,
  });
  final SettingsService settings;
  final AudioService audio;
  final CameraService? camera;
  final ConnectivityService? connectivity;
  @override
  State<SetupAssistant> createState() => _SetupAssistantState();
}

class _SetupAssistantState extends State<SetupAssistant> {
  static const titles = [
    'Welcome',
    'Display & touch',
    'Audio output',
    'Microphone',
    'Connectivity',
    'Projection',
    'Camera',
    'Vehicle integration',
    'Finish',
  ];
  late int _step;
  bool _pending = false;
  String? _error;
  final _touches = <int>{};
  @override
  void initState() {
    super.initState();
    _step = widget.settings
        .get(AppSettingKeys.setupStep)
        .clamp(0, titles.length - 1);
  }

  Future<void> _move(int next) async {
    setState(() {
      _pending = true;
      _error = null;
    });
    try {
      await widget.settings.set(AppSettingKeys.setupStep, next);
      if (!mounted) return;
      if (next == titles.length) {
        Navigator.pop(context);
        return;
      }
      setState(() => _step = next);
    } on Object {
      if (mounted) {
        setState(
          () => _error =
              'Could not save setup progress. Retry when storage is available.',
        );
      }
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Setup assistant')),
    body: ArgoSetupStep(
      index: _step,
      count: titles.length,
      title: titles[_step],
      pending: _pending,
      onBack: _step > 0 ? () => _move(_step - 1) : null,
      onNext: () => _move(_step + 1),
      onSkip: _step > 0 && _step < 8 ? () => _move(_step + 1) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null) Text(_error!),
          switch (_step) {
            0 => const Text(
              'Set up the connected hardware. Optional equipment can be set up later. Progress is saved as you continue; reopen this assistant in Settings → System.',
            ),
            1 => Column(
              children: [
                const Text(
                  'Touch each target to check reach and response. Display output selection remains with your desktop session.',
                ),
                Wrap(
                  spacing: 24,
                  runSpacing: 24,
                  children: [
                    for (var i = 0; i < 4; i++)
                      SizedBox(
                        width: 100,
                        height: 72,
                        child: OutlinedButton(
                          onPressed: () => setState(() => _touches.add(i)),
                          child: Text(
                            _touches.contains(i)
                                ? 'Confirmed'
                                : 'Target ${i + 1}',
                          ),
                        ),
                      ),
                  ],
                ),
                AppearanceSettingsCard(settings: widget.settings),
              ],
            ),
            2 => AudioSettingsCard(audio: widget.audio),
            3 =>
              widget.connectivity == null
                  ? const Text(
                      'Microphone discovery is unavailable in this session. Set up later when the audio service is available.',
                    )
                  : MicrophoneCard(service: widget.connectivity!),
            4 =>
              widget.connectivity == null
                  ? const Text(
                      'Connectivity service is unavailable. You can continue without a phone.',
                    )
                  : ConnectivitySettingsCard(
                      service: widget.connectivity!,
                      settings: widget.settings,
                    ),
            5 => const Text(
              'Connect a phone, then use Settings → Android Auto or CarPlay to configure projection. Receiver availability and pairing are shown there. Projection is optional.',
            ),
            6 =>
              widget.camera == null
                  ? const Text(
                      'No camera provider is installed. You can continue without a camera.',
                    )
                  : SizedBox(
                      height: 420,
                      child: CameraActivityScope(
                        active: false,
                        child: CameraPage(service: widget.camera),
                      ),
                    ),
            7 => const Text(
              'Vehicle integration is optional. Automatic reverse needs fresh normalized vehicle signals. Without them, manual camera preview remains available. Configure a supported integration in Vehicle settings; no vehicle signals are invented by setup.',
            ),
            _ => const Text(
              'Setup choices are saved. Skipped hardware can be configured later. This does not certify phone, vehicle or camera operation; test those on the target system while safely parked.',
            ),
          },
        ],
      ),
    ),
  );
}
