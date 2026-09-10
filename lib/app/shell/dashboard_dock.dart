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
    required this.left,
    required this.right,
    required this.onLeft,
    required this.onRight,
    required this.audio,
    required this.onVolume,
  });
  final double scale, left, right;
  final bool home, mediaVisible;
  final VoidCallback onHome, onMedia, onApps, onSettings;
  final ValueChanged<String> onClimate;
  final ValueChanged<double> onLeft, onRight;
  final AudioService? audio;
  final ValueChanged<double?> onVolume;
  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surfaceContainer,
    child: LayoutBuilder(
      builder: (context, c) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: math.max(c.maxWidth, 700 * scale),
          height: c.maxHeight,
          child: Row(
            children: [
              _button('Settings', Icons.settings_outlined, onSettings),
              Expanded(child: _temperature('Left', left, onLeft)),
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
              Expanded(child: _temperature('Right', right, onRight)),
              SizedBox(
                width: 80 * scale,
                height: double.infinity,
                child: DashboardVolume(
                  audio: audio,
                  scale: scale * 1.25,
                  onIndicator: onVolume,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  Widget _temperature(String side, double value, ValueChanged<double> change) =>
      Column(
        children: [
          const Text('DEMO', style: TextStyle(fontSize: 9, letterSpacing: 1)),
          Expanded(
            child: DashboardTemperature(
              side: side,
              value: value,
              onChange: change,
              onTap: () => onClimate(side),
              scale: scale,
            ),
          ),
        ],
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
