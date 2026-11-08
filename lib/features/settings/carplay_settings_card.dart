import '../projection/projection_recovery_panel.dart';
import '../../core/audio/microphone_ownership.dart';
import '../shared/argo_components.dart';
import '../shared/status_panel.dart';
import '../../core/projection/projection_types.dart';

import 'package:flutter/material.dart';

import '../../core/projection/carplay_settings_service.dart';
import '../../core/projection/projection_service.dart';
import '../../core/projection/projection_models.dart';

class CarPlaySettingsCard extends StatelessWidget {
  const CarPlaySettingsCard({
    required this.service,
    this.projection,
    this.onDevices,
    super.key,
  });
  final CarPlaySettingsService service;
  final ProjectionService? projection;
  final VoidCallback? onDevices;
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
                .where(
                  (s) =>
                      s.device.protocol == ProjectionProtocol.carPlay &&
                      s.state != ProjectionSessionState.failed &&
                      s.state != ProjectionSessionState.disconnected,
                )
                .toList() ??
            [];
        final session = sessions.firstOrNull;
        final running = service.current['running'] == true;
        final connecting = session?.state == ProjectionSessionState.connecting;
        final established = session != null && !connecting;
        final waiting =
            running &&
            !established &&
            service.available &&
            service.failure == null;
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const ArgoSection(title: 'Apple CarPlay', children: []),
              Text(
                MicrophoneOwnership.parse(
                  service.current['microphone_ownership'],
                ).message,
              ),
              const SizedBox(height: 12),
              Text(
                session == null
                    ? (service.current['phase'] as String? ??
                          'Waiting for CarPlay service')
                    : '${session.device.displayName} · ${switch (session.state) {
                        ProjectionSessionState.connecting => 'Connecting to iPhone',
                        ProjectionSessionState.ready => '${session.device.transport == ProjectionTransport.wifi ? 'Connected wirelessly' : 'Connected by USB'} — waiting for video',
                        ProjectionSessionState.streaming => session.device.transport == ProjectionTransport.wifi ? 'Connected wirelessly' : 'Connected by USB',
                        ProjectionSessionState.suspended => 'CarPlay suspended',
                        _ => 'Disconnected',
                      }}',
              ),
              if (waiting) ...[
                const SizedBox(height: 8),
                const LinearProgressIndicator(),
                const Text(
                  'Waiting for iPhone — complete any Use CarPlay approval on your phone.',
                ),
                if (session != null && service.current['phase'] is String)
                  Text(service.current['phase'] as String),
              ],
              if (service.failure case final failure?)
                ArgoStatusPanel(
                  status: ArgoStatus.failed,
                  summary: failure.summary,
                  failure: failure,
                  onRetry: service.refresh,
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
                title: const Text('Retry interrupted connection'),
                subtitle: const Text(
                  'Retry the selected iPhone after an unexpected disconnect. Startup is controlled in Devices.',
                ),
                value: settings['auto_connect'] == true,
                onChanged: enabled
                    ? (v) => service.configure({'auto_connect': v})
                    : null,
              ),
              if (service.current['wireless'] == true) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: ValueKey('carplay-transport-${settings['transport']}'),
                  decoration: const InputDecoration(
                    labelText: 'Connection method',
                    helperText: 'Changing the method stops the connection. Connect the device from Devices.',
                  ),
                  initialValue: settings['transport'] as String? ?? 'usb',
                  items: const [
                    DropdownMenuItem(value: 'usb', child: Text('USB cable')),
                    DropdownMenuItem(
                      value: 'wireless',
                      child: Text('Wireless · LIVI Link'),
                    ),
                  ],
                  onChanged: enabled
                      ? (value) {
                          if (value != null) {
                            service.configure({'transport': value});
                          }
                        }
                      : null,
                ),
                const SizedBox(height: 8),
                const Text(
                  'For wireless CarPlay, pair the iPhone with Argo CarPlay in Bluetooth settings. '
                  'LIVI Link provides its Wi-Fi and Bluetooth radios.',
                ),
              ],
              if (snapshot.data?.switchRecovery case final recovery?)
                ProjectionRecoveryPanel(
                  service: projection!,
                  decision: recovery,
                ),
              const SizedBox(height: 12),
              const Text(
                'Select, connect and disconnect your phone in Devices.',
              ),
              if (onDevices != null)
                TextButton.icon(
                  onPressed: onDevices,
                  icon: const Icon(Icons.devices_outlined),
                  label: const Text('Open Devices'),
                ),
              const SizedBox(height: 24),
              const Text(
                'Display changes apply on the next connection. Reconnect the device from Devices to apply them now.',
              ),
              if (service.measuredViewport case final viewport?) ...[
                const SizedBox(height: 12),
                Text(
                  'Dashboard above dock: ${viewport.$1.toStringAsFixed(0)} × ${viewport.$2.toStringAsFixed(0)}. '
                  'View Area follows this shape; Safe Area reserves the media controls. Applies on next connection.',
                ),
                if (service.current['viewport_supported'] != true)
                  const Text(
                    'Update the CarPlay daemon to enable dashboard fitting.',
                  ),
              ],
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
              if (service.current['wireless'] != true)
                const Text('Update the CarPlay service to enable wireless.'),
            ],
          ),
        );
      },
    ),
  );
}
