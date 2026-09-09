import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/projection/projection_settings_service.dart';
import '../../core/projection/projection_types.dart';

/// A settings editor, not a projection session or native-surface owner.
class ProjectionSettingsCard extends StatelessWidget {
  const ProjectionSettingsCard({required this.service, super.key});
  final ProjectionSettingsService service;
  @override
  Widget build(BuildContext context) => StreamBuilder<void>(
    stream: service.changes,
    builder: (context, _) {
      final state = service.current,
          caps = state.capabilities,
          p = service.requested;
      final enabled = caps != null && !service.saving;
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Android Auto',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const Text(
                'Display preferences for wired and wireless projection.',
              ),
              const SizedBox(height: 12),
              Text('Saved request: $p'),
              Text(
                state.active == null
                    ? 'Current session: none'
                    : 'Current session selected: ${state.active}',
              ),
              Text(
                state.pending == null
                    ? 'Next connection: not yet validated by the daemon'
                    : 'Next connection (validated): ${state.pending}',
              ),
              if (caps == null)
                const Text(
                  'Saved preferences remain visible. Connect the daemon to edit supported modes.',
                ),
              if (state.pending != null && state.pending != p && state.accepted)
                const Text('Saved request is awaiting daemon validation.'),
              if (state.rejection != null)
                Text(
                  'Request rejected: ${state.rejection}. Previous validated configuration retained.',
                ),
              if (service.notice != null) Text(service.notice!),
              const SizedBox(height: 12),
              const Text(
                'Applies on next phone connection. Changing settings does not disconnect the phone.',
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<(int, int)>(
                key: ValueKey('projection-resolution-${p.width}-${p.height}'),
                decoration: const InputDecoration(
                  labelText: 'Source resolution',
                ),
                initialValue: (p.width, p.height),
                items:
                    <(int, int)>{
                          ...(caps?.resolutions ?? const <(int, int)>[]),
                          (p.width, p.height),
                        }
                        .map(
                          (mode) => DropdownMenuItem(
                            value: mode,
                            child: Text('${mode.$1} × ${mode.$2}'),
                          ),
                        )
                        .toList(),
                onChanged: enabled
                    ? (mode) {
                        if (mode != null) {
                          unawaited(
                            service.update(
                              p.copyWith(width: mode.$1, height: mode.$2),
                            ),
                          );
                        }
                      }
                    : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                key: ValueKey('projection-fps-${p.framesPerSecond}'),
                decoration: const InputDecoration(
                  labelText: 'Source frame rate (FPS)',
                ),
                initialValue: p.framesPerSecond,
                items:
                    <int>{
                          ...(caps?.frameRates ?? const <int>[]),
                          p.framesPerSecond,
                        }
                        .map(
                          (fps) => DropdownMenuItem(
                            value: fps,
                            child: Text('$fps FPS'),
                          ),
                        )
                        .toList(),
                onChanged: enabled
                    ? (fps) {
                        if (fps != null) {
                          unawaited(
                            service.update(p.copyWith(framesPerSecond: fps)),
                          );
                        }
                      }
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: ValueKey('projection-dpi-${p.dpi}'),
                initialValue: '${p.dpi}',
                enabled: enabled,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Source DPI',
                  helperText: caps == null
                      ? 'Daemon capabilities unavailable'
                      : '${caps.minimumDpi}–${caps.maximumDpi}; press Enter to save',
                ),
                autovalidateMode: AutovalidateMode.onUserInteraction,
                validator: (value) {
                  final dpi = int.tryParse(value ?? '');
                  return caps != null &&
                          (dpi == null ||
                              dpi < caps.minimumDpi ||
                              dpi > caps.maximumDpi)
                      ? 'Enter DPI within ${caps.minimumDpi}–${caps.maximumDpi}'
                      : null;
                },
                onFieldSubmitted: (value) {
                  final dpi = int.tryParse(value);
                  if (caps != null &&
                      dpi != null &&
                      dpi >= caps.minimumDpi &&
                      dpi <= caps.maximumDpi) {
                    unawaited(service.update(p.copyWith(dpi: dpi)));
                  }
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<ProjectionDriverSide>(
                key: ValueKey('projection-driver-${p.driverSide.name}'),
                decoration: const InputDecoration(labelText: 'Driver side'),
                initialValue: p.driverSide,
                items: ProjectionDriverSide.values
                    .map(
                      (side) => DropdownMenuItem(
                        value: side,
                        child: Text(
                          side == ProjectionDriverSide.left ? 'Left' : 'Right',
                        ),
                      ),
                    )
                    .toList(),
                onChanged: enabled
                    ? (side) {
                        if (side != null) {
                          unawaited(
                            service.update(p.copyWith(driverSide: side)),
                          );
                        }
                      }
                    : null,
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: service.saving
                    ? null
                    : () => unawaited(service.reset()),
                child: const Text('Reset projection defaults'),
              ),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Technical details'),
                childrenPadding: const EdgeInsets.symmetric(vertical: 12),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Backend: ${state.message}'),
                  if (state.sessionId != null)
                    Text('Session: ${state.sessionId}'),
                  if (caps != null) Text('Daemon defaults: ${caps.defaults}'),
                  const Text(
                    'Saved safe-area preferences are retained but not applied by this backend.',
                  ),
                  const Text(
                    'Source FPS is not physical screen refresh rate. Source DPI is not Flutter DPR or presentation scale.',
                  ),
                  const Text(
                    'Session values describe selected negotiation parameters; decoded video dimensions and output-device audio format are not observed here.',
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Native playback formats (read-only)',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  for (final format in caps?.audio ?? [])
                    Text(
                      '${format.role}: PCM, ${format.rate / 1000} kHz, ${format.bits}-bit, ${format.channels == 2 ? 'stereo' : 'mono'}',
                    ),
                  if (caps == null)
                    const Text('Audio format capabilities unavailable.'),
                  const Text(
                    'Per-stream focus gain is separate from system master volume. Microphone capture is not implemented.',
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}
