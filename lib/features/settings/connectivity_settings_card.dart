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
        'cleanup',
      ].contains(s.phase);
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Devices & connectivity',
                style: Theme.of(context).textTheme.titleLarge,
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
              for (final choice in [
                (s.adapters, s.adapter, 'Bluetooth adapter', 'adapter'),
                (
                  s.networks,
                  s.interface,
                  'Projection Wi-Fi interface',
                  'interface',
                ),
              ])
                if (choice.$1.isNotEmpty)
                  DropdownButtonFormField<String>(
                    key: ValueKey('${choice.$4}:${choice.$2}'),
                    initialValue: choice.$1.any((r) => r.id == choice.$2)
                        ? choice.$2
                        : null,
                    decoration: InputDecoration(labelText: choice.$3),
                    items: choice.$1
                        .map(
                          (r) => DropdownMenuItem(
                            value: r.id,
                            child: Text(r.name),
                          ),
                        )
                        .toList(),
                    onChanged: s.available
                        ? (v) {
                            if (v != null) command(choice.$4, target: v);
                          }
                        : null,
                  ),
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
              for (final d in s.devices.where(
                (d) =>
                    d.paired ||
                    (s.discovering && d.id.startsWith('${s.adapter}/')),
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
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Wireless Android Auto'),
                value: s.enabled,
                subtitle: const Text(
                  'Development admission: TCP identity is not cryptographically bound to Bluetooth. Enable only on a controlled projection network.',
                ),
                onChanged: s.available
                    ? (v) => command('enable', accept: v)
                    : null,
              ),
              Text(
                'Wi-Fi: ${s.wifiConnected ? 'phone reports joined' : 'not joined'} · Projection: ${s.phase}',
              ),
              const Text(
                'Connect creates a dedicated secure AP on idle Wi-Fi. NetworkManager shares host internet via NAT. Firewall authorization may appear. Ethernet stays connected.',
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
