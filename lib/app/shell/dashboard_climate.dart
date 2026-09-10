import 'package:flutter/material.dart';

/// Presentation only. Demo values are never published as vehicle state.
class DashboardClimate extends StatefulWidget {
  const DashboardClimate({
    super.key,
    required this.onDismiss,
    this.demo = false,
  });
  final VoidCallback onDismiss;
  final bool demo;
  @override
  State<DashboardClimate> createState() => _DashboardClimateState();
}

class _DashboardClimateState extends State<DashboardClimate> {
  double _left = 21, _right = 21, _fan = 2;
  bool _ac = false;
  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surfaceContainerHigh,
    borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
    clipBehavior: Clip.antiAlias,
    child: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.demo ? 'Climate • INTERACTIVE DEMO' : 'Climate',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: 'Close climate',
                  onPressed: widget.onDismiss,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            Text(
              widget.demo
                  ? 'Simulated controls — no vehicle connection'
                  : 'Vehicle climate controls unavailable',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: _zone('Left', _left, (v) => setState(() => _left = v)),
                ),
                Expanded(
                  child: _zone(
                    'Right',
                    _right,
                    (v) => setState(() => _right = v),
                  ),
                ),
              ],
            ),
            Slider(
              value: _fan,
              min: 0,
              max: 5,
              divisions: 5,
              label: widget.demo ? 'Demo fan ${_fan.round()}' : 'Unavailable',
              onChanged: widget.demo ? (v) => setState(() => _fan = v) : null,
            ),
            Wrap(
              spacing: 12,
              children: [
                FilterChip(
                  label: const Text('A/C'),
                  selected: _ac,
                  onSelected: widget.demo
                      ? (v) => setState(() => _ac = v)
                      : null,
                ),
                const FilterChip(
                  label: Text('Auto'),
                  selected: false,
                  onSelected: null,
                ),
                const FilterChip(
                  label: Text('Defrost'),
                  selected: false,
                  onSelected: null,
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  Widget _zone(String name, double value, ValueChanged<double> change) =>
      Column(
        children: [
          Text(name),
          Text(
            widget.demo ? '${value.toStringAsFixed(1)}°' : '—',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                tooltip: '$name cooler',
                onPressed: widget.demo
                    ? () => change((value - .5).clamp(16, 30))
                    : null,
                icon: const Icon(Icons.remove),
              ),
              IconButton(
                tooltip: '$name warmer',
                onPressed: widget.demo
                    ? () => change((value + .5).clamp(16, 30))
                    : null,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        ],
      );
}
