import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/audio/audio_service.dart';
import '../../core/audio/audio_snapshot.dart';
import '../../core/connectivity/connectivity_service.dart';
import '../../core/projection/projection_models.dart';
import '../../core/projection/projection_service.dart';
import '../../core/projection/projection_types.dart';
import '../../features/projection/projection_page.dart'
    show selectedProjectionSession;

/// Stays above the Navigator, including setup and pushed settings pages. The
/// remaining constraints and safe-area insets belong to the page below it.
class DashboardStatusFrame extends StatelessWidget {
  const DashboardStatusFrame({
    super.key,
    required this.child,
    this.connectivity,
    this.projection,
    this.audio,
    this.clock,
  });
  final Widget child;
  final ConnectivityService? connectivity;
  final ProjectionService? projection;
  final AudioService? audio;
  final DateTime Function()? clock;

  @override
  Widget build(BuildContext context) => Overlay.wrap(
    child: ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            DashboardStatusBar(
              connectivity: connectivity,
              projection: projection,
              audio: audio,
              clock: clock,
            ),
            Expanded(
              key: const ValueKey('dashboard-client-area'),
              child: child,
            ),
          ],
        ),
      ),
    ),
  );
}

/// Persistent host information. Each source updates independently of the video
/// owner; these indicators never initiate radio or projection commands.
class DashboardStatusBar extends StatelessWidget {
  const DashboardStatusBar({
    super.key,
    this.connectivity,
    this.projection,
    this.audio,
    this.clock,
  });

  static const height = 48.0;
  final ConnectivityService? connectivity;
  final ProjectionService? projection;
  final AudioService? audio;
  final DateTime Function()? clock;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      key: const ValueKey('dashboard-status-bar'),
      height: height,
      child: Material(
        color: colors.surface,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: colors.outlineVariant.withValues(alpha: .45),
              ),
            ),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final effectiveWidth =
                  constraints.maxWidth /
                  math.max(1, MediaQuery.textScalerOf(context).scale(1));
              final labels = effectiveWidth >= 480;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: _DashboardClock(
                        clock: clock,
                        showDate: effectiveWidth >= 560,
                      ),
                    ),
                    const SizedBox(width: 12),
                    if (projection case final service?)
                      StreamBuilder<ProjectionSnapshot>(
                        stream: service.changes,
                        initialData: service.current,
                        builder: (context, snapshot) {
                          if (snapshot.hasError ||
                              !(snapshot.data?.backendAvailable ?? false)) {
                            return const _Indicator(
                              icon: Icons.phonelink_off_outlined,
                              description: 'Phone status unavailable',
                            );
                          }
                          final session = selectedProjectionSession(
                            snapshot.requireData,
                          );
                          if (session == null) {
                            return const _Indicator(
                              icon: Icons.phonelink_off_outlined,
                              description: 'Phone disconnected',
                            );
                          }
                          final name =
                              session.device.protocol ==
                                  ProjectionProtocol.carPlay
                              ? 'CarPlay'
                              : 'Android Auto';
                          final wireless =
                              session.device.transport ==
                              ProjectionTransport.wifi;
                          final state = switch (session.state) {
                            ProjectionSessionState.connecting => 'Connecting',
                            ProjectionSessionState.suspended => 'Suspended',
                            _ => 'Connected',
                          };
                          return _Indicator(
                            icon: wireless ? Icons.wifi : Icons.usb_rounded,
                            label: labels ? name : null,
                            description:
                                '$name · ${wireless ? 'Wireless' : 'USB'} · $state',
                            active: state == 'Connected',
                          );
                        },
                      ),
                    if (connectivity case final service?)
                      StreamBuilder<ConnectivitySnapshot>(
                        stream: service.connectivityChanges,
                        initialData: service.connectivity,
                        builder: (context, snapshot) {
                          final state = snapshot.data ?? service.connectivity;
                          final known =
                              !snapshot.hasError &&
                              state.available &&
                              state.daemonConnected;
                          final count = state.deviceGroups
                              .where((device) => device.connected)
                              .length;
                          final description = !known
                              ? 'Bluetooth status unavailable'
                              : count == 0
                              ? 'Bluetooth · No connected devices'
                              : 'Bluetooth · $count connected ${count == 1 ? 'device' : 'devices'}';
                          return Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _Indicator(
                                icon: known && state.discovering
                                    ? Icons.bluetooth_searching
                                    : known && count > 0
                                    ? Icons.bluetooth_connected
                                    : Icons.bluetooth,
                                description: description,
                                active: known && count > 0,
                              ),
                              if (known && state.voice?['muted'] == true)
                                const _Indicator(
                                  icon: Icons.mic_off_outlined,
                                  description: 'Microphone muted',
                                ),
                            ],
                          );
                        },
                      ),
                    if (audio case final service?)
                      StreamBuilder<AudioSnapshot>(
                        stream: service.changes,
                        initialData: service.current,
                        builder: (context, snapshot) {
                          final state = snapshot.data ?? service.current;
                          final available =
                              !snapshot.hasError && state.backendAvailable;
                          if (available && !state.muted) {
                            return const SizedBox.shrink();
                          }
                          return _Indicator(
                            icon: Icons.volume_off_outlined,
                            description: available
                                ? 'Sound muted'
                                : 'Audio output unavailable',
                          );
                        },
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Indicator extends StatelessWidget {
  const _Indicator({
    required this.icon,
    required this.description,
    this.label,
    this.active = false,
  });
  final IconData icon;
  final String description;
  final String? label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: description,
      excludeFromSemantics: true,
      child: Semantics(
        label: description,
        child: ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 20,
                  color: active ? colors.primary : colors.onSurfaceVariant,
                ),
                if (label != null) ...[
                  const SizedBox(width: 6),
                  Text(label!, style: Theme.of(context).textTheme.labelMedium),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DashboardClock extends StatefulWidget {
  const _DashboardClock({required this.showDate, this.clock});
  final bool showDate;
  final DateTime Function()? clock;
  @override
  State<_DashboardClock> createState() => _DashboardClockState();
}

class _DashboardClockState extends State<_DashboardClock>
    with WidgetsBindingObserver {
  late DateTime _now;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sample();
  }

  void _sample() {
    _timer?.cancel();
    _now = (widget.clock?.call() ?? DateTime.now()).toLocal();
    final remaining =
        Duration.microsecondsPerMinute -
        _now.second * Duration.microsecondsPerSecond -
        _now.millisecond * Duration.microsecondsPerMillisecond -
        _now.microsecond;
    _timer = Timer(Duration(microseconds: remaining), () {
      if (mounted) setState(_sample);
    });
  }

  @override
  void didUpdateWidget(covariant _DashboardClock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.clock != widget.clock) _sample();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) setState(_sample);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    final time = localizations.formatTimeOfDay(
      TimeOfDay.fromDateTime(_now),
      alwaysUse24HourFormat: true,
    );
    final date = localizations.formatMediumDate(_now);
    return Tooltip(
      message: '${localizations.formatFullDate(_now)} · $time',
      child: Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          height: 32,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  time,
                  key: const ValueKey('dashboard-clock'),
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w500,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                if (widget.showDate) ...[
                  const SizedBox(width: 16),
                  Text(
                    date,
                    key: const ValueKey('dashboard-date'),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
