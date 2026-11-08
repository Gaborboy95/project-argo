import 'package:flutter/material.dart';

import '../../core/connectivity/device_connection_service.dart';
import '../../core/connectivity/device_hub_models.dart';
import '../../core/projection/projection_types.dart';
import '../shared/argo_components.dart';

/// All connection actions refer to a physical phone. Protocol preferences live
/// on their own settings pages and never become a second device inventory.
class DeviceHubCard extends StatefulWidget {
  const DeviceHubCard({
    required this.service,
    this.onAndroidAutoSettings,
    this.onCarPlaySettings,
    super.key,
  });
  final DeviceConnectionService service;
  final VoidCallback? onAndroidAutoSettings, onCarPlaySettings;

  @override
  State<DeviceHubCard> createState() => _DeviceHubCardState();
}

class _DeviceHubCardState extends State<DeviceHubCard> {
  bool _pending = false;
  String? _error;

  Future<void> _run(Future<void> Function() action) async {
    if (_pending || widget.service.busy) return;
    setState(() {
      _pending = true;
      _error = null;
    });
    try {
      await action();
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<void>(
    stream: widget.service.changes,
    builder: (context, snapshot) {
      final service = widget.service;
      final busy = _pending || service.busy;
      final ready = !busy && !snapshot.hasError;
      final error = snapshot.hasError
          ? 'Device status is temporarily unavailable.'
          : _error ?? service.error;
      final pairing = service.pairingProtocol;
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Devices', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              const Text(
                'Choose a phone to connect. Its projection, audio and calls are managed together.',
              ),
              if (busy) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(),
              ],
              if (error != null) ...[
                const SizedBox(height: 12),
                Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 12),
              SwitchListTile(
                key: const ValueKey('device-startup-reconnect'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Reconnect selected phone at startup'),
                subtitle: const Text(
                  'Reconnect only the selected device using its connection type.',
                ),
                value: service.autoConnect,
                onChanged: ready
                    ? (value) => _run(() => service.setAutoConnect(value))
                    : null,
              ),
              const SizedBox(height: 12),
              if (pairing == null)
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      key: const ValueKey('add-android-phone'),
                      onPressed: ready
                          ? () => _run(
                              () => service.beginPairing(
                                ProjectionProtocol.androidAuto,
                              ),
                            )
                          : null,
                      icon: const Icon(Icons.add),
                      label: const Text('Add Android phone'),
                    ),
                    FilledButton.tonalIcon(
                      key: const ValueKey('add-iphone'),
                      onPressed: ready && service.carPlayAvailable
                          ? () => _run(
                              () => service.beginPairing(
                                ProjectionProtocol.carPlay,
                              ),
                            )
                          : null,
                      icon: const Icon(Icons.add),
                      label: const Text('Add iPhone'),
                    ),
                  ],
                )
              else ...[
                Text(
                  'Adding ${deviceProtocolLabel(pairing)} phone',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  pairing == ProjectionProtocol.carPlay
                      ? 'Use the connection method selected in CarPlay settings. For USB, plug in your iPhone and allow CarPlay. For wireless, open Bluetooth settings on your iPhone and choose Argo CarPlay; approve pairing in Argo and allow CarPlay on your phone.'
                      : 'Open Bluetooth settings on your Android phone. Choose the phone below to pair; approve any matching code in Argo.',
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: const ValueKey('cancel-device-pairing'),
                    onPressed: ready ? () => _run(service.cancelPairing) : null,
                    child: const Text('Cancel adding phone'),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              if (service.devices.isEmpty)
                Text(
                  pairing == null
                      ? 'No remembered devices. Add a phone to get started.'
                      : 'Waiting for a phone…',
                ),
              for (final device in service.devices)
                _phone(device, ready: ready, pairing: pairing != null),
              const Divider(height: 32),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (widget.onAndroidAutoSettings != null)
                    TextButton(
                      onPressed: widget.onAndroidAutoSettings,
                      child: const Text('Android Auto settings'),
                    ),
                  if (widget.onCarPlaySettings != null)
                    TextButton(
                      onPressed: widget.onCarPlaySettings,
                      child: const Text('CarPlay settings'),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );

  Widget _phone(
    DeviceHubDevice device, {
    required bool ready,
    required bool pairing,
  }) {
    final service = widget.service;
    final active = device.connected || device.connecting;
    final projectionActive =
        device.connecting || device.liveSessions.isNotEmpty;
    final partialProjection =
        device.connected && !projectionActive && device.protocol != null;
    final partialMedia =
        device.connected &&
        !device.connecting &&
        device.bluetoothOnly &&
        device.audioSource &&
        !device.mediaConnected;
    final usbProjection =
        device.id.startsWith('projection:') &&
        device.bluetoothAddress == null &&
        device.protocol != null;
    final connectable = device.paired || usbProjection;
    final linkCandidates =
        usbProjection &&
            device.liveSessions.any(
              (session) => session.device.transport == ProjectionTransport.usb,
            )
        ? service.devices
              .where((phone) => phone.bluetoothAddress != null && phone.paired)
              .toList()
        : const <DeviceHubDevice>[];
    final identified = device.protocol != null || device.bluetoothOnly;
    final chooseProtocol =
        !projectionActive || !identified || device.protocols.length > 1;
    final type = device.protocol == null
        ? device.bluetoothOnly
              ? 'Bluetooth'
              : 'Choose connection type'
        : deviceProtocolLabel(device.protocol!);
    final status = device.connecting
        ? 'Connecting…'
        : device.connected
        ? partialMedia
              ? 'Audio not connected'
              : partialProjection
              ? 'Bluetooth connected'
              : 'Connected'
        : device.paired
        ? 'Disconnected'
        : 'Nearby';
    return ArgoDeviceChoice(
      key: ValueKey(device.id),
      name: device.name,
      identifier: device.identifier,
      selected: device.selected,
      status: '$type · $status',
      actions: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (chooseProtocol) ...[
              DropdownButtonFormField<String>(
                key: ValueKey(
                  'device-protocol:${device.id}:${device.protocol?.name}:${device.bluetoothOnly}',
                ),
                isExpanded: true,
                initialValue: device.bluetoothOnly
                    ? 'bluetooth'
                    : device.protocol == null
                    ? null
                    : deviceProtocolValue(device.protocol!),
                decoration: const InputDecoration(
                  labelText: 'Connection type',
                  hintText: 'Choose for this phone',
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'android-auto',
                    child: Text('Android Auto'),
                  ),
                  DropdownMenuItem(value: 'carplay', child: Text('CarPlay')),
                  DropdownMenuItem(
                    value: 'bluetooth',
                    child: Text('Bluetooth only'),
                  ),
                ],
                onChanged: ready && !projectionActive
                    ? (value) {
                        if (value == null) return;
                        _run(
                          () => service.selectProtocol(
                            device.id,
                            deviceProtocolFromValue(value),
                          ),
                        );
                      }
                    : null,
              ),
              const SizedBox(height: 8),
            ],
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (!active && connectable || partialProjection || partialMedia)
                  FilledButton.icon(
                    key: ValueKey('device-connect:${device.id}'),
                    onPressed: ready && identified
                        ? () => _run(() => service.connect(device.id))
                        : null,
                    icon: const Icon(Icons.link),
                    label: const Text('Connect device'),
                  ),
                if (active)
                  OutlinedButton.icon(
                    key: ValueKey('device-disconnect:${device.id}'),
                    onPressed: ready
                        ? () => _run(() => service.disconnect(device.id))
                        : null,
                    icon: const Icon(Icons.link_off),
                    label: const Text('Disconnect device'),
                  )
                else if (!connectable)
                  FilledButton.icon(
                    key: ValueKey('device-pair:${device.id}'),
                    onPressed: ready && pairing
                        ? () => _run(() => service.pair(device.id))
                        : null,
                    icon: const Icon(Icons.bluetooth),
                    label: const Text('Pair device'),
                  ),
                if (linkCandidates.isNotEmpty)
                  PopupMenuButton<String>(
                    key: ValueKey('device-link:${device.id}'),
                    enabled: ready,
                    tooltip: 'Link to saved phone',
                    itemBuilder: (_) => [
                      for (final phone in linkCandidates)
                        PopupMenuItem(value: phone.id, child: Text(phone.name)),
                    ],
                    onSelected: (id) async {
                      final phone = linkCandidates
                          .where((phone) => phone.id == id)
                          .firstOrNull;
                      if (phone == null) return;
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: Text('Link to ${phone.name}?'),
                          content: const Text(
                            'Only link if this is the same phone. Its USB and Bluetooth connections will share one device entry.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('Cancel'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('Link device'),
                            ),
                          ],
                        ),
                      );
                      if (confirmed == true && mounted) {
                        await _run(() => service.linkDevice(device.id, id));
                      }
                    },
                    child: const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                      child: Text('Link to saved phone'),
                    ),
                  ),
                if (device.paired)
                  TextButton(
                    key: ValueKey('device-forget:${device.id}'),
                    onPressed: ready
                        ? () async {
                            if (await confirmArgoAction(
                                  context,
                                  title: 'Forget ${device.name}?',
                                  explanation: 'Disconnect this device and remove its saved pairings and connection preferences from Argo.',
                                  action: 'Forget device',
                                ) &&
                                mounted) {
                              await _run(() => service.forget(device.id));
                            }
                          }
                        : null,
                    child: const Text('Forget device'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
