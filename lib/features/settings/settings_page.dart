import '../../core/camera/camera_service.dart';
import '../setup/setup_assistant.dart';
import '../shared/argo_components.dart';
import '../../core/projection/carplay_settings_service.dart';
import '../../core/projection/projection_service.dart';
import 'carplay_settings_card.dart';
import '../../core/projection/carplay_link_diagnostics.dart';
import 'carplay_link_settings_card.dart';
import '../../core/lifecycle/application_exit_service.dart';
import '../calls/calls_page.dart';
import 'application_settings_card.dart';

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
    this.carPlayDiagnostics,
    this.carPlaySettings,
    this.projection,
    this.exit,
    this.modelsPage,
    this.camera,
    super.key,
  });
  final Widget? modelsPage;
  final CameraService? camera;
  final ApplicationExitService? exit;
  final AudioService audio;
  final ProjectionSettingsService? projectionSettings;
  final SettingsService? settings;
  final ConnectivityService? connectivity;
  final CarPlayLinkDiagnostics? carPlayDiagnostics;
  final CarPlaySettingsService? carPlaySettings;
  final ProjectionService? projection;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String? selectedSection;
  @override
  Widget build(BuildContext context) {
    final sections = <(String, IconData, Widget)>[
      (
        'Sound',
        Icons.volume_up_outlined,
        Column(
          children: [
            AudioSettingsCard(audio: widget.audio),
            if (widget.connectivity != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: MicrophoneCard(service: widget.connectivity!),
              ),
          ],
        ),
      ),
      if (widget.connectivity != null || widget.carPlayDiagnostics != null)
        (
          'Devices',
          Icons.devices_outlined,
          Column(
            children: [
              if (widget.connectivity != null)
                ConnectivitySettingsCard(
                  service: widget.connectivity!,
                  settings: widget.settings,
                ),
            ],
          ),
        ),
      if (widget.projectionSettings != null)
        (
          'Android Auto',
          Icons.directions_car_outlined,
          ProjectionSettingsCard(service: widget.projectionSettings!),
        ),
      if (widget.carPlaySettings != null || widget.carPlayDiagnostics != null)
        (
          'CarPlay',
          Icons.phone_iphone,
          Column(
            children: [
              if (widget.carPlaySettings != null)
                CarPlaySettingsCard(
                  service: widget.carPlaySettings!,
                  projection: widget.projection,
                ),
              if (widget.carPlayDiagnostics != null)
                CarPlayLinkSettingsCard(service: widget.carPlayDiagnostics!),
            ],
          ),
        ),
      if (widget.settings != null)
        (
          'Appearance',
          Icons.palette_outlined,
          AppearanceSettingsCard(settings: widget.settings!),
        ),
      if (widget.modelsPage != null)
        ('AI & Models', Icons.model_training, widget.modelsPage!),
    ];
    if (widget.settings != null) {
      sections.add((
        'System',
        Icons.settings_suggest_outlined,
        ArgoSection(
          title: 'Setup and diagnostics',
          children: [
            ListTile(
              title: const Text('Setup assistant'),
              subtitle: const Text('Resume or revisit hardware setup'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SetupAssistant(
                    settings: widget.settings!,
                    audio: widget.audio,
                    camera: widget.camera,
                    connectivity: widget.connectivity,
                  ),
                ),
              ),
            ),
            const ListTile(
              title: Text('System diagnostics'),
              subtitle: Text(
                'Run argoctl doctor in this desktop session for read-only runtime and service checks.',
              ),
            ),
          ],
        ),
      ));
    }
    if (widget.exit != null) {
      sections.add((
        'Application',
        Icons.power_settings_new,
        ApplicationSettingsCard(exit: widget.exit!),
      ));
    }
    final requestedSection =
        selectedSection ??
        (widget.carPlaySettings != null ? 'CarPlay' : 'Sound');
    final index = sections
        .indexWhere((section) => section.$1 == requestedSection)
        .clamp(0, sections.length - 1);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide =
            constraints.maxWidth >= 760 && constraints.maxHeight >= 360;
        final padding = constraints.maxWidth < 600 ? 12.0 : 24.0;
        Widget destination(int i) => Semantics(
          selected: index == i,
          child: Padding(
            padding: EdgeInsets.only(bottom: wide ? 8 : 0, right: wide ? 0 : 8),
            child: Material(
              color: index == i
                  ? colors.secondaryContainer
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => setState(() => selectedSection = sections[i].$1),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 17,
                  ),
                  child: Row(
                    mainAxisSize: wide ? MainAxisSize.max : MainAxisSize.min,
                    children: [
                      Icon(
                        sections[i].$2,
                        size: 26,
                        color: index == i
                            ? colors.onSecondaryContainer
                            : colors.onSurfaceVariant,
                      ),
                      const SizedBox(width: 14),
                      Text(
                        sections[i].$1,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: index == i
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: index == i
                              ? colors.onSecondaryContainer
                              : colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        final navigation = wide
            ? SizedBox(
                width: 210,
                child: ListView(
                  children: [
                    for (var i = 0; i < sections.length; i++) destination(i),
                  ],
                ),
              )
            : SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (var i = 0; i < sections.length; i++) destination(i),
                  ],
                ),
              );
        final content = Material(
          color: colors.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(
              color: colors.outlineVariant.withValues(alpha: .35),
            ),
          ),
          child: Theme(
            data: theme.copyWith(
              // One quiet content surface instead of nested floating cards.
              cardTheme: const CardThemeData(
                elevation: 0,
                margin: EdgeInsets.zero,
                color: Colors.transparent,
                surfaceTintColor: Colors.transparent,
                shape: RoundedRectangleBorder(),
              ),
              listTileTheme: theme.listTileTheme.copyWith(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 6,
                ),
              ),
              inputDecorationTheme: InputDecorationTheme(
                filled: true,
                fillColor: colors.surfaceContainerHighest.withValues(
                  alpha: .55,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 20,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: colors.primary),
                ),
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: ListView(
                key: PageStorageKey(sections[index].$1),
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  if (sections[index].$1 == 'Application')
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: sections[index].$3,
                    )
                  else
                    sections[index].$3,
                ],
              ),
            ),
          ),
        );
        return Padding(
          padding: EdgeInsets.all(padding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 6, bottom: 18),
                child: Text(
                  'Settings',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (widget.connectivity != null)
                StreamBuilder<ConnectivitySnapshot>(
                  stream: widget.connectivity!.connectivityChanges,
                  initialData: widget.connectivity!.connectivity,
                  builder: (context, snapshot) =>
                      snapshot.data?.prompt != null &&
                          sections[index].$1 != 'Devices'
                      ? Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              icon: const Icon(Icons.bluetooth_searching),
                              label: Text(
                                'Pairing request from ${snapshot.data!.prompt!.name} — review in Devices',
                              ),
                              onPressed: () =>
                                  setState(() => selectedSection = 'Devices'),
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              if (!wide) ...[navigation, const SizedBox(height: 12)],
              Expanded(
                child: wide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          navigation,
                          const SizedBox(width: 24),
                          Expanded(child: content),
                        ],
                      )
                    : content,
              ),
            ],
          ),
        );
      },
    );
  }
}
