import 'package:flutter/material.dart';

import 'dashboard_temperature.dart';

/// UI preview only. Separate zone and airflow groups leave room for future
/// vehicle-backed seat controls without pretending they are implemented.
class DashboardClimate extends StatefulWidget {
  const DashboardClimate({
    super.key,
    required this.onDismiss,
    this.left = 22,
    this.right = 22,
    this.onLeft,
    this.onRight,
  });
  final VoidCallback onDismiss;
  final double left, right;
  final ValueChanged<double>? onLeft, onRight;
  @override
  State<DashboardClimate> createState() => _DashboardClimateState();
}

class _DashboardClimateState extends State<DashboardClimate> {
  double _fan = 2;
  bool _ac = false;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Climate preview',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            IconButton(
              tooltip: 'Close climate',
              onPressed: widget.onDismiss,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        const Text('Interactive demo — no vehicle connection'),
        const SizedBox(height: 16),
        SizedBox(
          height: 180,
          child: Row(
            children: [
              for (final side in ['Left', 'Right'])
                Expanded(
                  child: DashboardTemperature(
                    side: side,
                    value: side == 'Left' ? widget.left : widget.right,
                    scale: 1.3,
                    onChange: (v) =>
                        (side == 'Left' ? widget.onLeft : widget.onRight)?.call(
                          v,
                        ),
                    onTap: () {},
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 32),
        const Text('Airflow • demo'),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              tooltip: 'Lower fan',
              onPressed: () => setState(() => _fan = (_fan - 1).clamp(0, 5)),
              icon: const Icon(Icons.remove),
            ),
            Text('${_fan.round()} / 5'),
            IconButton(
              tooltip: 'Raise fan',
              onPressed: () => setState(() => _fan = (_fan + 1).clamp(0, 5)),
              icon: const Icon(Icons.add),
            ),
          ],
        ),
        FilterChip(
          label: const Text('A/C • demo'),
          selected: _ac,
          onSelected: (v) => setState(() => _ac = v),
        ),
      ],
    ),
  );
}
