import 'package:flutter/material.dart';

import '../../core/audio/audio_service.dart';
import '../../core/audio/audio_snapshot.dart';
import '../../core/audio/audio_types.dart';

class AudioSettingsCard extends StatelessWidget {
  const AudioSettingsCard({required this.audio, super.key});
  final AudioService audio;
  @override
  Widget build(BuildContext context) => StreamBuilder<AudioSnapshot>(
    stream: audio.changes,
    initialData: audio.current,
    builder: (context, snapshot) {
      final s = snapshot.requireData;
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Sound', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                s.backendAvailable
                    ? 'Output · ${s.selectedOutput ?? 'System default'}'
                    : 'Host audio is unavailable. Use the release launcher with PipeWire running; ARGO_AUDIO_BACKEND=disabled turns these controls off.',
              ),
              const SizedBox(height: 20),
              AudioSettingSlider(
                label: 'Volume',
                value: s.masterVolume,
                minimum: 0,
                maximum: 1,
                enabled: s.backendAvailable && s.capabilities.masterVolume,
                percentage: true,
                commit: audio.setMasterVolume,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Mute output'),
                value: s.muted,
                onChanged: s.backendAvailable && s.capabilities.mute
                    ? (v) => _run(context, () => audio.setMuted(v))
                    : null,
              ),
              if (s.capabilities.balance)
                AudioSettingSlider(
                  label: 'Balance',
                  value: s.balance,
                  minimum: -1,
                  maximum: 1,
                  enabled: s.backendAvailable,
                  commit: audio.setBalance,
                ),
              if (s.capabilities.fader)
                AudioSettingSlider(
                  label: 'Fader',
                  value: s.fader,
                  minimum: -1,
                  maximum: 1,
                  enabled: s.backendAvailable,
                  commit: audio.setFader,
                ),
              if (s.capabilities.equalizer)
                for (final band
                    in <(String, double, Future<void> Function(double))>[
                      (
                        'Bass (dB)',
                        s.equalizer.bassDb,
                        (v) =>
                            audio.setEqualizer(s.equalizer.copyWith(bassDb: v)),
                      ),
                      (
                        'Mid (dB)',
                        s.equalizer.midDb,
                        (v) =>
                            audio.setEqualizer(s.equalizer.copyWith(midDb: v)),
                      ),
                      (
                        'Treble (dB)',
                        s.equalizer.trebleDb,
                        (v) => audio.setEqualizer(
                          s.equalizer.copyWith(trebleDb: v),
                        ),
                      ),
                    ])
                  AudioSettingSlider(
                    label: band.$1,
                    value: band.$2,
                    minimum: AudioEqualizer.minimumDb,
                    maximum: AudioEqualizer.maximumDb,
                    enabled: s.backendAvailable,
                    commit: band.$3,
                  ),
              if (!s.capabilities.balance &&
                  !s.capabilities.fader &&
                  !s.capabilities.equalizer)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    'This output supports volume and mute. Balance, fader and equalizer require an audio backend with those controls.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

Future<void> _run(BuildContext context, Future<void> Function() action) async {
  try {
    await action();
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Audio control failed: $e')));
    }
  }
}

/// Preview follows the drag; only the committed value is sent to the host.
class AudioSettingSlider extends StatefulWidget {
  const AudioSettingSlider({
    required this.label,
    required this.value,
    required this.minimum,
    required this.maximum,
    required this.enabled,
    required this.commit,
    this.percentage = false,
    super.key,
  });
  final String label;
  final double value, minimum, maximum;
  final bool enabled, percentage;
  final Future<void> Function(double) commit;
  @override
  State<AudioSettingSlider> createState() => _AudioSettingSliderState();
}

class _AudioSettingSliderState extends State<AudioSettingSlider> {
  double? preview;
  bool saving = false;
  @override
  Widget build(BuildContext context) {
    final value = (preview ?? widget.value).clamp(
      widget.minimum,
      widget.maximum,
    );
    final label = widget.percentage
        ? '${(value * 100).round()}%'
        : value.toStringAsFixed(1);
    return Column(
      children: [
        Row(
          children: [
            Expanded(child: Text(widget.label)),
            Text(label),
          ],
        ),
        Slider(
          value: value,
          min: widget.minimum,
          max: widget.maximum,
          label: label,
          onChanged: widget.enabled && !saving
              ? (v) => setState(() => preview = v)
              : null,
          onChangeEnd: widget.enabled && !saving
              ? (v) async {
                  setState(() => saving = true);
                  await _run(context, () => widget.commit(v));
                  if (mounted) {
                    setState(() {
                      saving = false;
                      preview = null;
                    });
                  }
                }
              : null,
        ),
      ],
    );
  }
}
