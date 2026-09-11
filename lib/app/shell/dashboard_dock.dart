import '../../core/climate/climate_service.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/audio/audio_service.dart';
import 'dashboard_volume.dart';
import 'dashboard_temperature.dart';

class DashboardDock extends StatelessWidget {
  const DashboardDock({
    super.key,
    required this.scale,
    required this.home,
    required this.mediaVisible,
    required this.onHome,
    required this.onMedia,
    required this.onApps,
    required this.onSettings,
    required this.onClimate,
    this.climate,
    required this.audio,
    required this.onVolume,
  });
  final double scale;
  final ClimateService? climate;
  final bool home, mediaVisible;
  final VoidCallback onHome, onMedia, onApps, onSettings;
  final ValueChanged<String> onClimate;
  final AudioService? audio;
  final ValueChanged<double?> onVolume;
  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surfaceContainer,
    child: LayoutBuilder(
      builder: (context, c) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: math.max(c.maxWidth, 740 * scale),
          height: c.maxHeight,
          child: Row(
            children: [
              SizedBox(width: 20 * scale),
              _button('Settings', Icons.settings_outlined, onSettings),
              Expanded(child: _temperature('Left', 'front_left')),
              const VerticalDivider(width: 1, indent: 22, endIndent: 22),
              _button('Home', Icons.home_outlined, onHome, selected: home),
              _button(
                'Media strip',
                Icons.music_note_outlined,
                onMedia,
                selected: mediaVisible,
              ),
              _button('Apps', Icons.apps_rounded, onApps),
              _button('Camera unavailable', Icons.videocam_outlined, null),
              const VerticalDivider(width: 1, indent: 22, endIndent: 22),
              Expanded(child: _temperature('Right', 'front_right')),
              SizedBox(
                width: 80 * scale,
                height: double.infinity,
                child: DashboardVolume(
                  audio: audio,
                  scale: scale * 1.25,
                  onIndicator: onVolume,
                ),
              ),
              SizedBox(width: 20 * scale),
            ],
          ),
        ),
      ),
    ),
  );
  Widget _temperature(String side, String zone) => ClimateTemperatureControl(
    service: climate,
    zone: zone,
    side: side,
    scale: scale,
    onTap: () => onClimate(side),
  );
  Widget _button(
    String label,
    IconData icon,
    VoidCallback? tap, {
    bool selected = false,
  }) => SizedBox(
    width: 80 * scale,
    height: double.infinity,
    child: IconButton(
      tooltip: label,
      isSelected: selected,
      onPressed: tap,
      icon: Icon(icon, size: 36 * scale),
    ),
  );
}
