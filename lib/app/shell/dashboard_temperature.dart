import 'dart:async';

import 'package:flutter/material.dart';

/// Local preview/requested values only; never publishes simulated vehicle data.
class DashboardTemperature extends StatefulWidget {
  const DashboardTemperature({
    super.key,
    required this.side,
    required this.value,
    required this.onChange,
    required this.onTap,
    required this.scale,
  });
  final String side;
  final double value, scale;
  final ValueChanged<double> onChange;
  final VoidCallback onTap;
  @override
  State<DashboardTemperature> createState() => _DashboardTemperatureState();
}

class _DashboardTemperatureState extends State<DashboardTemperature> {
  Timer? _hide;
  bool _adjusting = false;
  double _start = 22, _distance = 0;
  void _change(double value) {
    final next = ((value.clamp(18, 26) * 2).round() / 2).clamp(18.0, 26.0);
    if (next != widget.value) widget.onChange(next);
    _hide?.cancel();
    setState(() => _adjusting = true);
    _hide = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _adjusting = false);
    });
  }

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final row = (c.maxHeight - 6).clamp(0.0, double.infinity).toDouble() / 3;
      final icon = (30 * widget.scale).clamp(0.0, row).toDouble();
      return Column(
        children: [
          SizedBox(
            height: row,
            width: double.infinity,
            child: IconButton(
              padding: EdgeInsets.zero,
              tooltip: '${widget.side} warmer',
              onPressed: () => _change(widget.value + .5),
              icon: Icon(Icons.arrow_drop_up, size: icon),
            ),
          ),
          SizedBox(
            height: row,
            width: double.infinity,
            child: GestureDetector(
              key: ValueKey('temperature-${widget.side}'),
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              onHorizontalDragStart: (_) {
                _start = widget.value;
                _distance = 0;
              },
              onHorizontalDragUpdate: (e) {
                _distance += e.delta.dx;
                _change(_start + _distance / 32);
              },
              child: Semantics(
                button: true,
                label: '${widget.side} climate preview',
                value: '${widget.value.toStringAsFixed(1)} degrees',
                onTap: widget.onTap,
                child: Center(
                  child: Text(
                    '${widget.value.toStringAsFixed(1)}°',
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: (36 * widget.scale)
                          .clamp(0.0, row * .85)
                          .toDouble(),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
          ),
          SizedBox(
            height: row,
            width: double.infinity,
            child: IconButton(
              padding: EdgeInsets.zero,
              tooltip: '${widget.side} cooler',
              onPressed: () => _change(widget.value - .5),
              icon: Icon(Icons.arrow_drop_down, size: icon),
            ),
          ),
          SizedBox(
            height: 6,
            child: _adjusting
                ? LayoutBuilder(
                    builder: (_, bar) => Stack(
                      children: [
                        Container(
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              colors: [Colors.blue, Colors.grey, Colors.red],
                            ),
                          ),
                        ),
                        Positioned(
                          left: ((widget.value - 18) / 8 * (bar.maxWidth - 4))
                              .clamp(0, bar.maxWidth),
                          width: 4,
                          top: 0,
                          bottom: 0,
                          child: const ColoredBox(color: Colors.white),
                        ),
                      ],
                    ),
                  )
                : const SizedBox(),
          ),
        ],
      );
    },
  );
}
