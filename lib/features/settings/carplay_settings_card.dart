import '../../core/projection/projection_types.dart';
import 'package:flutter/material.dart';

import '../../core/projection/carplay_settings_service.dart';
import '../../core/projection/projection_service.dart';
import '../../core/projection/projection_models.dart';

class CarPlaySettingsCard extends StatelessWidget {
  const CarPlaySettingsCard({
    required this.service,
    this.projection,
    super.key,
  });
  final CarPlaySettingsService service;
  final ProjectionService? projection;
  @override
  Widget build(BuildContext context) => StreamBuilder<void>(
    stream: service.changes,
    builder: (context, _) => StreamBuilder<ProjectionSnapshot>(
      stream: projection?.changes,
      initialData: projection?.current,
      builder: (context, snapshot) {
        final settings = service.current['settings'] as Map? ?? const {};
        final enabled = service.available && !service.saving;
        final sessions =
            snapshot.data?.sessions
                .where((s) => s.device.protocol == ProjectionProtocol.carPlay)
                .toList() ??
            [];
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Apple CarPlay',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              Text(
                sessions.isEmpty
                    ? (service.current['phase'] as String? ??
                          'Waiting for CarPlay service')
                    : '${sessions.first.device.displayName} · Connected by USB',
              ),
              if (service.error != null)
                Text(
                  service.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Enable CarPlay'),
                value: settings['enabled'] == true,
                onChanged: enabled
                    ? (v) => service.configure({'enabled': v})
                    : null,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Auto-connect'),
                subtitle: const Text(
                  'Connect on startup and after an unexpected disconnect.',
                ),
                value: settings['auto_connect'] == true,
                onChanged: enabled
                    ? (v) => service.configure({'auto_connect': v})
                    : null,
              ),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  FilledButton(
                    onPressed: enabled && settings['enabled'] == true
                        ? service.connect
                        : null,
                    child: Text(sessions.isEmpty ? 'Connect' : 'Reconnect'),
                  ),
                  OutlinedButton(
                    onPressed: enabled && service.current['running'] == true
                        ? service.disconnect
                        : null,
                    child: const Text('Disconnect'),
                  ),
                  if (sessions.isNotEmpty && projection != null)
                    OutlinedButton(
                      onPressed: () => projection!.activate(sessions.first.id),
                      child: const Text('Make active'),
                    ),
                ],
              ),
              const SizedBox(height: 24),
              const Text(
                'Display changes apply on the next connection. Reconnect to apply them now.',
              ),
              const SizedBox(height: 16),
              if (settings.isNotEmpty) ...[
                DropdownButtonFormField<(int, int)>(
                  key: ValueKey(
                    'carplay-size-${settings['width']}-${settings['height']}',
                  ),
                  decoration: const InputDecoration(labelText: 'Resolution'),
                  initialValue: (
                    settings['width'] as int,
                    settings['height'] as int,
                  ),
                  items:
                      <(int, int)>{
                            (800, 480),
                            (1280, 720),
                            (1920, 1080),
                            (
                              settings['width'] as int,
                              settings['height'] as int,
                            ),
                          }
                          .map(
                            (size) => DropdownMenuItem(
                              value: size,
                              child: Text('${size.$1} × ${size.$2}'),
                            ),
                          )
                          .toList(),
                  onChanged: enabled
                      ? (v) {
                          if (v != null) {
                            service.configure({'width': v.$1, 'height': v.$2});
                          }
                        }
                      : null,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  key: ValueKey('carplay-fps-${settings['fps']}'),
                  decoration: const InputDecoration(labelText: 'Frame rate'),
                  initialValue: settings['fps'] as int,
                  items: [
                    for (final fps in [30, 60])
                      DropdownMenuItem(value: fps, child: Text('$fps FPS')),
                  ],
                  onChanged: enabled
                      ? (v) => service.configure({'fps': v})
                      : null,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Right-hand drive'),
                  value: settings['right_hand_drive'] == true,
                  onChanged: enabled
                      ? (v) => service.configure({'right_hand_drive': v})
                      : null,
                ),
              ],
              const SizedBox(height: 12),
              const Text(
                'Microphone selection and mute are shared with Sound settings. Wired CarPlay uses LIVI Link for authentication.',
              ),
              const SizedBox(height: 12),
              const Text('Wireless CarPlay is not available in this build.'),
            ],
          ),
        );
      },
    ),
  );
}
