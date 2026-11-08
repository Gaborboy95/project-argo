import '../../core/camera/camera_service.dart';
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
    this.camera,
    this.onCamera,
    required this.audio,
    required this.onVolume,
  });
  final double scale;
  final CameraService? camera;
  final VoidCallback? onCamera;
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
      builder: (context, c) {
        if (c.maxWidth < 740 * scale && c.maxHeight >= 128) {
          return Column(
            key: const ValueKey('compact-dashboard-dock'),
            children: [
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: _temperature('Left', 'front_left', compact: true),
                    ),
                    SizedBox(width: 80 * scale, child: _volume()),
                    Expanded(
                      child: _temperature(
                        'Right',
                        'front_right',
                        compact: true,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                height: 60,
                child: Row(
                  children: [
                    Expanded(
                      child: _button(
                        'Settings',
                        Icons.settings_outlined,
                        onSettings,
                      ),
                    ),
                    Expanded(
                      child: _button(
                        'Home',
                        Icons.home_outlined,
                        onHome,
                        selected: home,
                      ),
                    ),
                    Expanded(
                      child: _button(
                        'Media strip',
                        Icons.music_note_outlined,
                        onMedia,
                        selected: mediaVisible,
                      ),
                    ),
                    Expanded(
                      child: _button('Apps', Icons.apps_rounded, onApps),
                    ),
                    Expanded(child: _camera()),
                  ],
                ),
              ),
            ],
          );
        }
        return SingleChildScrollView(
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
                _camera(),
                const VerticalDivider(width: 1, indent: 22, endIndent: 22),
                Expanded(child: _temperature('Right', 'front_right')),
                SizedBox(
                  width: 80 * scale,
                  height: double.infinity,
                  child: _volume(),
                ),
                SizedBox(width: 20 * scale),
              ],
            ),
          ),
        );
      },
    ),
  );
  Widget _volume() =>
      DashboardVolume(audio: audio, scale: scale * 1.25, onIndicator: onVolume);
  Widget _camera() => StreamBuilder<CameraSnapshot>(
    stream: camera?.changes,
    initialData: camera?.current,
    builder: (context, snapshot) => _button(
      'Camera',
      Icons.videocam_outlined,
      snapshot.data?.rearUsable == true ? onCamera : null,
    ),
  );
  Widget _temperature(String side, String zone, {bool compact = false}) =>
      ClimateTemperatureControl(
        service: climate,
        zone: zone,
        side: side,
        scale: scale,
        compact: compact,
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
    child: LayoutBuilder(
      builder: (context, c) => IconButton(
        tooltip: label,
        isSelected: selected,
        onPressed: tap,
        icon: Icon(
          icon,
          size: math.min(36 * scale, math.min(c.maxWidth, c.maxHeight) * .65),
        ),
      ),
    ),
  );
}
