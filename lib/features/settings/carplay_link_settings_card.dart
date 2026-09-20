import 'package:flutter/material.dart';

import '../../core/projection/carplay_link_diagnostics.dart';

/// Read-only health and accurate capability limits for the prepared accessory.
class CarPlayLinkSettingsCard extends StatelessWidget {
  const CarPlayLinkSettingsCard({required this.service, super.key});
  final CarPlayLinkDiagnostics service;

  @override
  Widget build(BuildContext context) => StreamBuilder<CarPlayLinkHealth>(
    stream: service.changes,
    initialData: service.current,
    builder: (context, snapshot) {
      final health = snapshot.requireData;
      final theme = Theme.of(context);
      Widget row(String label, String value) =>
          ListTile(dense: true, title: Text(label), subtitle: Text(value));
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('CarPlay · LIVI Link', style: theme.textTheme.titleLarge),
              const SizedBox(height: 12),
              const Text(
                'LIVI Link provides authentication for native CarPlay. '
                'Accessory health is separate from the iPhone connection.',
              ),
              const SizedBox(height: 12),
              row(
                'Diagnostics',
                health.serviceAvailable ? 'Available' : 'Unavailable',
              ),
              row(
                'LIVI Link discovery',
                health.linkResolved ? 'Resolved' : 'Unavailable',
              ),
              row('MFi coprocessor', switch (health.mfi) {
                CarPlayMfiHealth.ready =>
                  'Certificate and protocol query ready',
                CarPlayMfiHealth.certificateOnly =>
                  'Certificate available; protocol query failed',
                CarPlayMfiHealth.unavailable => 'Unavailable',
              }),
              if (health.protocolMajor != null)
                row(
                  'Authentication protocol generation',
                  '${health.protocolMajor}',
                ),
              row(
                'Wi-Fi control',
                health.wifiControlAvailable ? 'Available' : 'Unavailable',
              ),
              if (health.accessPointEnabled != null)
                row(
                  'Access point reported by Link',
                  health.accessPointEnabled! ? 'On' : 'Off',
                ),
              if (health.bluetoothEnabled != null)
                row(
                  'Bluetooth radio reported by Link',
                  health.bluetoothEnabled! ? 'On' : 'Off',
                ),
              row('Bluetooth bridge / iAP handoff', 'Not probed'),
              if (health.error != null)
                Text(
                  health.error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              if (health.address != null)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text('Advanced diagnostics'),
                  children: [row('Resolved address', health.address!)],
                ),
              const Divider(height: 32),
              Text(
                'Open-source acknowledgement',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              const Text(
                'f-io / Lasse Heitgres — LIVI\n'
                'Argo’s CarPlay and LIVI Link interoperability work was informed '
                'by LIVI – Linux In-Vehicle Infotainment. Thank you to f-io and '
                'the LIVI contributors for their native CarPlay, iAP2 and MFi '
                'reference work. LIVI is licensed GPL-3.0-or-later.',
              ),
              const SizedBox(height: 8),
              const SelectableText('https://github.com/f-io/LIVI'),
            ],
          ),
        ),
      );
    },
  );
}
