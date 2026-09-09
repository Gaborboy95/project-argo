import 'package:flutter/material.dart';

import '../../core/audio/audio_service.dart';
import '../../core/connectivity/connectivity_service.dart';
import '../../core/projection/projection_settings_service.dart';
import '../../core/settings/settings_service.dart';
import 'appearance_settings_card.dart';
import 'audio_settings_card.dart';
import 'connectivity_settings_card.dart';
import 'projection_settings_card.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    required this.audio,
    this.projectionSettings,
    this.settings,
    this.connectivity,
    super.key,
  });
  final AudioService audio;
  final ProjectionSettingsService? projectionSettings;
  final SettingsService? settings;
  final ConnectivityService? connectivity;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int selected = 0;
  @override
  Widget build(BuildContext context) {
    final sections = <(String, IconData, Widget)>[
      (
        'Sound',
        Icons.volume_up_outlined,
        AudioSettingsCard(audio: widget.audio),
      ),
      if (widget.connectivity != null)
        (
          'Devices',
          Icons.devices_outlined,
          ConnectivitySettingsCard(service: widget.connectivity!),
        ),
      if (widget.projectionSettings != null)
        (
          'Projection',
          Icons.directions_car_outlined,
          ProjectionSettingsCard(service: widget.projectionSettings!),
        ),
      if (widget.settings != null)
        (
          'Appearance',
          Icons.palette_outlined,
          AppearanceSettingsCard(settings: widget.settings!),
        ),
    ];
    final index = selected.clamp(0, sections.length - 1);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Settings', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              for (var i = 0; i < sections.length; i++)
                ChoiceChip(
                  avatar: Icon(sections[i].$2, size: 20),
                  label: Text(sections[i].$1),
                  selected: index == i,
                  onSelected: (_) => setState(() => selected = i),
                ),
            ],
          ),
          if (widget.connectivity != null)
            StreamBuilder<ConnectivitySnapshot>(
              stream: widget.connectivity!.connectivityChanges,
              initialData: widget.connectivity!.connectivity,
              builder: (context, snapshot) =>
                  snapshot.data?.prompt != null &&
                      sections[index].$1 != 'Devices'
                  ? TextButton.icon(
                      icon: const Icon(Icons.bluetooth_searching),
                      label: Text(
                        'Pairing request from ${snapshot.data!.prompt!.name} — review in Devices',
                      ),
                      onPressed: () => setState(
                        () => selected = sections.indexWhere(
                          (s) => s.$1 == 'Devices',
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          const SizedBox(height: 16),
          Expanded(
            child: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 880),
                child: Theme(
                  data: Theme.of(context).copyWith(
                    inputDecorationTheme: InputDecorationTheme(
                      filled: true,
                      fillColor: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 18,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  child: ListView(
                    key: PageStorageKey(sections[index].$1),
                    children: [sections[index].$3],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
