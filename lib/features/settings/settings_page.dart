import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/audio/audio_service.dart';
import '../../core/audio/audio_snapshot.dart';
import '../../core/audio/audio_types.dart';
import '../../core/projection/projection_settings_service.dart';
import 'projection_settings_card.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({required this.audio, this.projectionSettings, super.key});

  final ProjectionSettingsService? projectionSettings;

  final AudioService audio;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AudioSnapshot>(
      stream: audio.changes,
      initialData: audio.current,
      builder: (context, snapshot) {
        final state = snapshot.requireData;
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            if (projectionSettings != null)
              ProjectionSettingsCard(service: projectionSettings!),
            Text('Audio', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 12),
            Text(
              state.backendAvailable
                  ? 'System output: ${state.selectedOutput ?? 'default'}'
                  : 'Host audio control is disabled',
            ),
            _slider(
              label: 'Volume',
              value: state.masterVolume,
              minimum: 0,
              maximum: 1,
              enabled:
                  state.backendAvailable && state.capabilities.masterVolume,
              onChanged: audio.setMasterVolume,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Mute'),
              value: state.muted,
              onChanged: state.backendAvailable && state.capabilities.mute
                  ? (value) => _run(audio.setMuted(value))
                  : null,
            ),
            _slider(
              label: 'Balance',
              value: state.balance,
              minimum: -1,
              maximum: 1,
              enabled: state.backendAvailable && state.capabilities.balance,
              onChanged: audio.setBalance,
            ),
            _slider(
              label: 'Fader',
              value: state.fader,
              minimum: -1,
              maximum: 1,
              enabled: state.backendAvailable && state.capabilities.fader,
              onChanged: audio.setFader,
            ),
            for (final band
                in <(String, double, Future<void> Function(double))>[
                  (
                    'Bass',
                    state.equalizer.bassDb,
                    (value) => audio.setEqualizer(
                      state.equalizer.copyWith(bassDb: value),
                    ),
                  ),
                  (
                    'Mid',
                    state.equalizer.midDb,
                    (value) => audio.setEqualizer(
                      state.equalizer.copyWith(midDb: value),
                    ),
                  ),
                  (
                    'Treble',
                    state.equalizer.trebleDb,
                    (value) => audio.setEqualizer(
                      state.equalizer.copyWith(trebleDb: value),
                    ),
                  ),
                ])
              _slider(
                label: '${band.$1} (dB)',
                value: band.$2,
                minimum: AudioEqualizer.minimumDb,
                maximum: AudioEqualizer.maximumDb,
                enabled: state.backendAvailable && state.capabilities.equalizer,
                onChanged: band.$3,
              ),
          ],
        );
      },
    );
  }

  static Widget _slider({
    required String label,
    required double value,
    required double minimum,
    required double maximum,
    required bool enabled,
    required Future<void> Function(double) onChanged,
  }) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(label),
    subtitle: Slider(
      value: value.clamp(minimum, maximum),
      min: minimum,
      max: maximum,
      onChanged: enabled ? (_) {} : null,
      onChangeEnd: enabled ? (value) => _run(onChanged(value)) : null,
    ),
    trailing: Text(value.toStringAsFixed(2)),
  );

  static void _run(Future<void> operation) {
    unawaited(operation.catchError((Object _) {}));
  }
}
