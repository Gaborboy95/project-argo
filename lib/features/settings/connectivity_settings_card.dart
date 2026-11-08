import 'package:flutter/material.dart';

import '../../core/connectivity/connectivity_service.dart';
import '../../core/connectivity/device_connection_service.dart';
import 'device_hub_card.dart';
import '../../core/projection/carplay_settings_service.dart';
import '../../core/projection/projection_service.dart';
import '../../core/settings/settings_service.dart';
import '../shared/argo_components.dart';

enum ConnectivitySettingsMode { devices, androidAuto }

/// Shared device hub, or Android Auto's separate connection configuration.
class ConnectivitySettingsCard extends StatefulWidget {
  const ConnectivitySettingsCard({
    required this.service,
    this.settings,
    this.deviceConnections,
    this.mode = ConnectivitySettingsMode.devices,
    this.carPlaySettings,
    this.projection,
    this.onAndroidAutoSettings,
    this.onCarPlaySettings,
    super.key,
  });
  final SettingsService? settings;
  final DeviceConnectionService? deviceConnections;
  final ConnectivityService service;
  final ConnectivitySettingsMode mode;
  final CarPlaySettingsService? carPlaySettings;
  final ProjectionService? projection;
  final VoidCallback? onAndroidAutoSettings, onCarPlaySettings;
  @override
  State<ConnectivitySettingsCard> createState() =>
      _ConnectivitySettingsCardState();
}

class _ConnectivitySettingsCardState extends State<ConnectivitySettingsCard> {
  String? _error;
  bool _pending = false;
  static const _activePhases = {
    'preparing',
    'bootstrap',
    'connecting',
    'projecting',
    'streaming',
    'backoff',
    'retrying',
    'cleanup',
  };
  Future<void> _run(Future<void> Function() action) async {
    if (_pending) return;
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

  Future<void> _command(
    String action, {
    String target = '',
    bool accept = false,
  }) => _run(
    () => widget.service.connectivityCommand(
      action,
      target: target,
      accept: accept,
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (widget.mode == ConnectivitySettingsMode.devices) {
      final devices = widget.deviceConnections;
      if (devices == null) {
        return const Card(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text('Device management is unavailable in this session.'),
          ),
        );
      }
      return DeviceHubCard(
        service: devices,
        onAndroidAutoSettings: widget.onAndroidAutoSettings,
        onCarPlaySettings: widget.onCarPlaySettings,
      );
    }
    return StreamBuilder<ConnectivitySnapshot>(
      stream: widget.service.connectivityChanges,
      initialData: widget.service.connectivity,
      builder: (context, snapshot) {
        final state = snapshot.requireData;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ArgoSection(
                  title: 'Android Auto connectivity',
                  children: const [],
                ),
                if (_pending) const LinearProgressIndicator(),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ..._androidAutoSettings(state),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _radioChoice(
    ConnectivitySnapshot state,
    List<ConnectivityRadio> choices,
    String selected,
    String label,
    String action,
  ) => DropdownButtonFormField<String>(
    isExpanded: true,
    key: ValueKey('$action:$selected'),
    initialValue: choices.any((r) => r.id == selected) ? selected : null,
    decoration: InputDecoration(labelText: label),
    items: choices
        .map(
          (r) => DropdownMenuItem(
            value: r.id,
            child: Text(r.name, overflow: TextOverflow.ellipsis),
          ),
        )
        .toList(),
    onChanged: state.available && !_pending
        ? (value) {
            if (value != null) _command(action, target: value);
          }
        : null,
  );

  List<Widget> _androidAutoSettings(ConnectivitySnapshot state) {
    final ready = state.available && !_pending;
    final active = _activePhases.contains(state.phase);
    return [
      const Text(
        'Pair phones and start connections in Devices. These settings configure wireless Android Auto.',
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Wireless Android Auto'),
        value: state.enabled,
        subtitle: const Text(
          'Enabling alone does not start a hotspot. Connect explicitly from Devices.',
        ),
        onChanged: ready && (state.enabled || state.wirelessAvailable == true)
            ? (value) => _command('enable', accept: value)
            : null,
      ),
      const SizedBox(height: 16),
      if (state.networks.isNotEmpty)
        _radioChoice(
          state,
          state.networks,
          state.interface,
          'Projection Wi-Fi interface',
          'interface',
        ),
      for (final radio in state.networks.where((r) => r.id == state.interface))
        if (radio.detail != null)
          Text(radio.detail!, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 16),
      if (state.band == '2.4ghz' || state.band == '5ghz')
        DropdownButtonFormField<String>(
          key: ValueKey('band:${state.band}'),
          initialValue: state.band,
          decoration: const InputDecoration(labelText: 'Projection AP band'),
          items: const [
            DropdownMenuItem(value: '2.4ghz', child: Text('2.4 GHz')),
            DropdownMenuItem(value: '5ghz', child: Text('5 GHz')),
          ],
          onChanged: ready
              ? (value) {
                  if (value != null) _command('band', target: value);
                }
              : null,
        )
      else if (state.available)
        const Text(
          'AP band selection requires the updated connectivity daemon.',
        ),
      if (active)
        const Text(
          'Band changes apply after Disconnect, then Connect. The current attempt keeps its band.',
        ),
      if (state.apFrequencyMhz != null)
        Text(
          'Active AP configuration: ${state.apFrequencyMhz! < 3000 ? '2.4' : '5'} GHz (${state.apFrequencyMhz} MHz)',
        ),
      const SizedBox(height: 12),
      Text(state.detail),
      if (state.cleanupError.isNotEmpty)
        Text(
          state.cleanupError,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      const Text(
        'Connect uses the selected idle Wi-Fi interface and shares host internet. Only use a controlled projection network; TCP identity is not cryptographically bound to Bluetooth.',
      ),
    ];
  }
}
