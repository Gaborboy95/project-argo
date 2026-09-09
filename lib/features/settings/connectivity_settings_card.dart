import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/connectivity/connectivity_service.dart';

class ConnectivitySettingsCard extends StatefulWidget {
  const ConnectivitySettingsCard({required this.service, super.key});
  final ConnectivityService service;
  @override
  State<ConnectivitySettingsCard> createState() =>
      _ConnectivitySettingsCardState();
}

class _ConnectivitySettingsCardState extends State<ConnectivitySettingsCard> {
  String? error;
  void command(
    String action, {
    String target = '',
    bool accept = false,
    int prompt = 0,
  }) {
    setState(() => error = null);
    unawaited(
      widget.service
          .connectivityCommand(
            action,
            target: target,
            accept: accept,
            prompt: prompt,
          )
          .catchError((Object e) {
            if (mounted) setState(() => error = '$e');
          }),
    );
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<ConnectivitySnapshot>(
    stream: widget.service.connectivityChanges,
    initialData: widget.service.connectivity,
    builder: (context, snapshot) {
      final s = snapshot.requireData;
      final prompt = s.prompt;
      final active = [
        'preparing',
        'bootstrap',
        'connecting',
        'projecting',
        'streaming',
        'backoff',
        'retrying',
        'cleanup',
      ].contains(s.phase);
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Devices & connectivity',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (prompt != null)
                Card(
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${prompt.name}\n${prompt.device}\n${prompt.text}\nExpires after 30 seconds.',
                        ),
                        Wrap(
                          spacing: 8,
                          children: [
                            FilledButton(
                              onPressed: () => command(
                                'confirm',
                                prompt: prompt.id,
                                accept: true,
                              ),
                              child: const Text('Confirm match'),
                            ),
                            OutlinedButton(
                              onPressed: () =>
                                  command('confirm', prompt: prompt.id),
                              child: const Text('Reject'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              Text(error ?? s.detail),
              if (s.cleanupError.isNotEmpty)
                Text(
                  s.cleanupError,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (active && s.phase != 'streaming')
                const LinearProgressIndicator(),
              const SizedBox(height: 20),
              for (final choice in [
                (
                  s.adapters,
                  s.adapter,
                  'Bluetooth adapter (all tasks)',
                  'adapter',
                ),
                (
                  s.networks,
                  s.interface,
                  'Projection Wi-Fi interface',
                  'interface',
                ),
              ])
                if (choice.$1.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: DropdownButtonFormField<String>(
                      isExpanded: true,
                      key: ValueKey('${choice.$4}:${choice.$2}'),
                      initialValue: choice.$1.any((r) => r.id == choice.$2)
                          ? choice.$2
                          : null,
                      decoration: InputDecoration(
                        labelText: choice.$3,
                        filled: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 18,
                        ),
                      ),
                      items: choice.$1
                          .map(
                            (r) => DropdownMenuItem(
                              value: r.id,
                              child: Text(
                                r.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: s.available
                          ? (v) {
                              if (v != null) command(choice.$4, target: v);
                            }
                          : null,
                    ),
                  ),
              const SizedBox(height: 12),
              for (final radio in s.networks.where((r) => r.id == s.interface))
                if (radio.detail != null)
                  Text(
                    radio.detail!,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              const SizedBox(height: 12),
              if (s.band == '2.4ghz' || s.band == '5ghz')
                DropdownButtonFormField<String>(
                  key: ValueKey('band:${s.band}'),
                  initialValue: s.band,
                  decoration: const InputDecoration(
                    labelText: 'Projection AP band',
                    filled: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 18,
                    ),
                  ),
                  items: const [
                    DropdownMenuItem(value: '2.4ghz', child: Text('2.4 GHz')),
                    DropdownMenuItem(value: '5ghz', child: Text('5 GHz')),
                  ],
                  onChanged: s.available
                      ? (v) {
                          if (v != null) command('band', target: v);
                        }
                      : null,
                )
              else if (s.available)
                const Text(
                  'AP band selection requires the updated connectivity daemon.',
                ),
              if (active)
                const Text(
                  'Band changes apply after Disconnect, then Connect. The current attempt keeps its band.',
                ),
              if (s.apFrequencyMhz != null)
                Text(
                  'Active AP configuration: ${s.apFrequencyMhz! < 3000 ? "2.4" : "5"} GHz (${s.apFrequencyMhz} MHz)',
                ),
              const SizedBox(height: 20),
              const Divider(),
              const SizedBox(height: 12),
              Text(
                'Pairing & devices',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: s.available
                        ? () => command('discover', accept: !s.discovering)
                        : null,
                    child: Text(
                      s.discovering
                          ? 'Stop discovery'
                          : 'Discover devices (60s)',
                    ),
                  ),
                ],
              ),
              const Text(
                'Open Bluetooth settings on the phone, then Pair below. Incoming pairing uses the desktop agent; Argo does not replace it.',
              ),
              for (final d in s.devices.where(
                (d) =>
                    d.id.startsWith('${s.adapter}/') &&
                    (d.paired || s.discovering),
              ))
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(d.name),
                  subtitle: Text(
                    '${d.id}\n${d.paired ? 'Bluetooth paired' : 'Not paired'} · ${d.connected ? 'Bluetooth connected' : 'Bluetooth disconnected'}',
                  ),
                  trailing: Wrap(
                    spacing: 4,
                    children: [
                      if (!d.paired)
                        TextButton(
                          onPressed: s.discovering
                              ? () => command('pair', target: d.id)
                              : null,
                          child: const Text('Pair'),
                        ),
                      if (d.paired)
                        TextButton(
                          onPressed: () => command('select', target: d.id),
                          child: Text(
                            s.selected == d.id
                                ? 'Selected phone'
                                : 'Select for AA',
                          ),
                        ),
                      if (d.paired)
                        IconButton(
                          tooltip: 'Forget device and stop wireless',
                          onPressed: () => command('forget', target: d.id),
                          icon: const Icon(Icons.link_off),
                        ),
                    ],
                  ),
                ),
              const Divider(height: 32),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Wireless Android Auto'),
                value: s.enabled,
                subtitle: const Text(
                  'Available automatically when the selected Wi-Fi adapter supports a permitted AP channel. Connect starts projection; enabling alone does not start a hotspot.',
                ),
                onChanged:
                    s.available && (s.enabled || s.wirelessAvailable == true)
                    ? (v) => command('enable', accept: v)
                    : null,
              ),
              Text(
                'Wi-Fi: ${s.wifiConnected ? 'phone reports joined' : 'not joined'} · Projection: ${s.phase}',
              ),
              const Text(
                'Connect uses the selected idle Wi-Fi interface. Host internet is shared via NAT. Experimental admission: only use a controlled projection network; TCP identity is not cryptographically bound to Bluetooth.',
              ),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    onPressed:
                        s.available &&
                            s.enabled &&
                            s.selected.isNotEmpty &&
                            !active
                        ? () => command('connect')
                        : null,
                    child: const Text('Connect'),
                  ),
                  OutlinedButton(
                    onPressed: s.available && s.enabled
                        ? () => command('disconnect')
                        : null,
                    child: const Text('Disconnect'),
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
