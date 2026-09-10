import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/connectivity/connectivity_service.dart';
import 'phonebook_card.dart';

/// A view of the shared native call/microphone services; no Bluetooth profiles.
class CallsPage extends StatefulWidget {
  const CallsPage({required this.service, super.key});
  final ConnectivityService? service;
  @override
  State<CallsPage> createState() => _CallsPageState();
}

class _CallsPageState extends State<CallsPage> {
  final number = TextEditingController();
  String? phone, error;
  bool busy = false;
  @override
  void dispose() {
    number.dispose();
    super.dispose();
  }

  Future<void> command(
    String action, {
    String target = '',
    bool accept = false,
  }) async {
    setState(() {
      busy = true;
      error = null;
    });
    final operation = DateTime.now().microsecondsSinceEpoch;
    final done = Completer<void>();
    final subscription = widget.service!.connectivityChanges.listen((s) {
      if (done.isCompleted) return;
      if (s.calls?['operation'] == operation) {
        final failure = s.calls?['error'];
        if (failure == null) {
          done.complete();
        } else {
          done.completeError(StateError(failure as String));
        }
      } else if (!s.available) {
        done.completeError(StateError('Call controller disconnected'));
      }
    });
    try {
      await widget.service!.connectivityCommand(
        action,
        target: target,
        accept: accept,
        prompt: operation,
      );
      await done.future.timeout(const Duration(seconds: 16));
    } on Object catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      await subscription.cancel();
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    if (service == null) {
      return const Center(child: Text('Bluetooth call service unavailable'));
    }
    return StreamBuilder<ConnectivitySnapshot>(
      stream: service.connectivityChanges,
      initialData: service.connectivity,
      builder: (context, snapshot) {
        final state = snapshot.data!;
        final calls = state.calls;
        final devices = state.devices
            .where((d) => d.paired && d.id.startsWith('${state.adapter}/'))
            .toList();
        final chosen = devices.any((d) => d.id == phone)
            ? phone
            : devices.any((d) => d.id == state.selected)
            ? state.selected
            : null;
        final connected =
            calls?['phase'] == 'connected' && calls?['device'] == chosen;
        final entries = (calls?['calls'] as List?) ?? [];
        return Padding(
          padding: const EdgeInsets.all(24),
          child: ListView(
            children: [
              Text('Calls', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: chosen,
                decoration: const InputDecoration(
                  labelText: 'Paired phone on the selected Bluetooth adapter',
                ),
                items: [
                  for (final d in devices)
                    DropdownMenuItem(value: d.id, child: Text(d.name)),
                ],
                onChanged: busy ? null : (v) => setState(() => phone = v),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed: busy || chosen == null
                        ? null
                        : () => command('callsConnect', target: chosen),
                    icon: const Icon(Icons.phone_in_talk),
                    label: const Text('Connect calls'),
                  ),
                  OutlinedButton(
                    onPressed: busy ? null : () => command('callsDisconnect'),
                    child: const Text('Disconnect calls'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                'Calling SIM: controlled by the phone. Single-SIM phones use their SIM; on dual-SIM phones set the default calling SIM or answer any SIM prompt on the phone. This calling backend does not expose a SIM selector.',
              ),
              Text(
                calls?['detail'] as String? ??
                    'Checking installed PipeWire telephony support',
              ),
              if (calls?['error'] != null)
                Text(
                  calls!['error'] as String,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              const Divider(height: 32),
              MicrophoneCard(service: service),
              const Divider(height: 32),
              for (final call in entries)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          call['name'] as String? ??
                              call['number'] as String? ??
                              'Unknown caller',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        Text(call['state'] as String),
                        Wrap(
                          spacing: 12,
                          children: [
                            if (call['state'] == 'incoming' ||
                                call['state'] == 'waiting')
                              FilledButton(
                                onPressed: busy
                                    ? null
                                    : () => command(
                                        'callsAnswer',
                                        target: call['id'] as String,
                                      ),
                                child: const Text('Answer'),
                              ),
                            OutlinedButton(
                              onPressed: busy
                                  ? null
                                  : () => command(
                                      'callsHangup',
                                      target: call['id'] as String,
                                    ),
                              child: const Text('Hang up / reject'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              TextField(
                controller: number,
                keyboardType: TextInputType.phone,
                maxLength: 64,
                decoration: const InputDecoration(
                  labelText: 'Telephone number',
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: busy || !connected
                      ? null
                      : () => command('callsDial', target: number.text.trim()),
                  icon: const Icon(Icons.call),
                  label: const Text('Call'),
                ),
              ),
              if (entries.isNotEmpty)
                TextButton(
                  onPressed: busy ? null : () => command('callsAudio'),
                  child: const Text(
                    'Retry call audio after connecting microphone',
                  ),
                ),
              PhonebookCard(
                book: calls?['phonebook'] as Map<String, dynamic>?,
                enabled: connected && !busy,
                request: (action, {target = ''}) =>
                    command(action, target: target),
                choose: (value) {
                  setState(() => number.text = value);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Number filled above. Press Call to dial using the phone’s SIM policy.',
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class MicrophoneCard extends StatelessWidget {
  const MicrophoneCard({required this.service, super.key});
  final ConnectivityService service;
  Future<void> _command(
    BuildContext context,
    String action, {
    String target = '',
    bool accept = false,
  }) async {
    try {
      await service.connectivityCommand(action, target: target, accept: accept);
    } on Object catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<ConnectivitySnapshot>(
    stream: service.connectivityChanges,
    initialData: service.connectivity,
    builder: (context, event) {
      final voice = event.data?.voice;
      final inputs = (voice?['inputs'] as List?) ?? [];
      final selected = voice?['selected'] as String?;
      final owner = voice?['owner'] as String? ?? '';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Voice input', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey(selected),
            initialValue: inputs.any((i) => i['id'] == selected)
                ? selected
                : null,
            decoration: const InputDecoration(
              labelText: 'USB ADC or mixed PipeWire input',
            ),
            items: [
              for (final i in inputs)
                DropdownMenuItem(
                  value: i['id'] as String,
                  child: Text(i['name'] as String),
                ),
            ],
            onChanged: owner.isNotEmpty
                ? null
                : (v) {
                    if (v != null) {
                      _command(context, 'microphone', target: v);
                    }
                  },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Mute microphone'),
            value: voice?['muted'] == true,
            onChanged: (v) => _command(context, 'microphoneMute', accept: v),
          ),
          Text(voice?['detail'] as String? ?? 'Microphone service unavailable'),
          if (owner.isNotEmpty)
            Text(
              'Microphone owner: ${switch (owner) {
                'androidAuto' => 'Android Auto',
                'bluetoothCall' => 'Bluetooth call',
                _ => owner,
              }}',
            ),
          const Text(
            'The selected input is mixed to mono. Use an ADC mix node to choose channel weights. No echo cancellation or beamforming is applied by Argo.',
          ),
        ],
      );
    },
  );
}
