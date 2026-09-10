import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/audio/audio_service.dart';
import 'dashboard_volume.dart';

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
    required this.onClimateDrag,
    required this.onClimateEnd,
    required this.audio,
    required this.onVolume,
  });
  final double scale;
  final bool home, mediaVisible;
  final VoidCallback onHome,
      onMedia,
      onApps,
      onSettings,
      onClimate,
      onClimateEnd;
  final ValueChanged<double> onClimateDrag;
  final AudioService? audio;
  final ValueChanged<double?> onVolume;
  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surfaceContainer,
    child: Column(
      children: [
        GestureDetector(
          key: const ValueKey('climate-handle'),
          behavior: HitTestBehavior.opaque,
          onTap: onClimate,
          onVerticalDragUpdate: (e) => onClimateDrag(e.delta.dy),
          onVerticalDragEnd: (_) => onClimateEnd(),
          onVerticalDragCancel: onClimateEnd,
          child: SizedBox(
            height: 24,
            width: double.infinity,
            child: Center(
              child: Container(
                width: 40,
                height: 3,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: math.max(constraints.maxWidth, 528 * scale),
                height: constraints.maxHeight,
                child: Row(
                  children: [
                    _button('Settings', Icons.settings_outlined, onSettings),
                    Expanded(child: _climate('Left climate')),
                    SizedBox(
                      width: 256 * scale,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _button(
                            'Home',
                            Icons.home_outlined,
                            onHome,
                            selected: home,
                          ),
                          _button(
                            'Media strip',
                            Icons.music_note_outlined,
                            onMedia,
                            selected: mediaVisible,
                          ),
                          _button('Apps', Icons.apps_rounded, onApps),
                          _button(
                            'Camera unavailable',
                            Icons.videocam_outlined,
                            null,
                          ),
                        ],
                      ),
                    ),
                    Expanded(child: _climate('Right climate')),
                    SizedBox(
                      width: 64 * scale,
                      height: double.infinity,
                      child: DashboardVolume(
                        audio: audio,
                        scale: scale,
                        onIndicator: onVolume,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
  Widget _climate(String label) => SizedBox(
    width: 72 * scale,
    height: double.infinity,
    child: TextButton(
      onPressed: onClimate,
      child: Semantics(
        label: label,
        child: Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Icon(Icons.thermostat, size: 20 * scale),
            Text('—', style: TextStyle(fontSize: 22 * scale)),
          ],
        ),
      ),
    ),
  );
  Widget _button(
    String label,
    IconData icon,
    VoidCallback? onTap, {
    bool selected = false,
  }) => SizedBox(
    width: 64 * scale,
    height: double.infinity,
    child: IconButton(
      tooltip: label,
      isSelected: selected,
      onPressed: onTap,
      icon: Icon(icon, size: 26 * scale),
    ),
  );
}
