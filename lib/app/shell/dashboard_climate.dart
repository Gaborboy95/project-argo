import 'package:flutter/material.dart';

import '../../core/climate/climate_service.dart';
import 'dashboard_temperature.dart';

class DashboardClimate extends StatelessWidget {
  const DashboardClimate({
    super.key,
    required this.onDismiss,
    this.service,
    this.compact = false,
  });
  final VoidCallback onDismiss;
  final ClimateService? service;
  final bool compact;
  @override
  Widget build(BuildContext context) => StreamBuilder<ClimateSnapshot>(
    stream: service?.changes,
    initialData: service?.current ?? ClimateSnapshot(),
    builder: (context, snapshot) {
      final state = snapshot.requireData,
          caps = snapshot.requireData.capabilities;
      final fan = state.fan.displayed;
      return Padding(
        padding: EdgeInsets.all(compact ? 16 : 24),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    state.simulated && !compact
                        ? 'Climate • simulation'
                        : 'Climate',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                IconButton(
                  tooltip: 'Close climate',
                  onPressed: onDismiss,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            if (!state.available) const Text('Vehicle climate unavailable'),
            if (state.simulated && !compact)
              const Text('Simulated feedback — no vehicle actuation'),
            SizedBox(height: compact ? 8 : 16),
            SizedBox(
              height: compact ? 144 : 180,
              child: Row(
                children: [
                  for (final side in [
                    ('Left', 'front_left'),
                    ('Right', 'front_right'),
                  ])
                    Expanded(
                      child: ClimateTemperatureControl(
                        service: service,
                        zone: side.$2,
                        side: side.$1,
                        scale: 1.3,
                      ),
                    ),
                ],
              ),
            ),
            if (state.simulated && compact)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text('Simulated feedback — no vehicle actuation'),
              ),
            if (caps?.fan case final range?) ...[
              const Divider(height: 32),
              const Text('Fan'),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: 'Lower fan',
                    onPressed: state.available
                        ? () => service!.requestFanLevel(
                            range.snap((fan ?? range.min) - range.step),
                          )
                        : null,
                    icon: const Icon(Icons.remove),
                  ),
                  Text(
                    fan == null
                        ? '--'
                        : '$fan / ${range.max}${state.fan.pending ? ' …' : ''}',
                  ),
                  IconButton(
                    tooltip: 'Raise fan',
                    onPressed: state.available
                        ? () => service!.requestFanLevel(
                            range.snap((fan ?? range.min) + range.step),
                          )
                        : null,
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
              if (state.fan.failure != null) Text(state.fan.failure!),
            ],
            if (caps?.acSupported == true) ...[
              FilterChip(
                label: Text(
                  'A/C${state.ac.displayed == null ? ' — unknown' : ''}${state.ac.pending ? ' …' : ''}',
                ),
                selected: state.ac.displayed == true,
                onSelected: state.available
                    ? (v) => service!.requestAc(v)
                    : null,
              ),
              if (state.ac.failure != null) Text(state.ac.failure!),
            ],
          ],
        ),
      );
    },
  );
}
