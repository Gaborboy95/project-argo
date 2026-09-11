import 'dart:async';

import '../../core/climate/climate_service.dart';

import 'package:flutter/material.dart';

/// Temperature-owned horizontal gestures; vertical gestures belong to the panel.
class DashboardTemperature extends StatefulWidget {
  const DashboardTemperature({
    super.key,
    required this.side,
    required this.value,
    required this.onChange,
    required this.onTap,
    required this.scale,
    this.range,
    this.pending = false,
    this.failure,
    this.onImmediate,
  });
  final String side;
  final double? value;
  final double scale;
  final ClimateTemperatureRange? range;
  final bool pending;
  final String? failure;
  final ValueChanged<double>? onImmediate;
  final ValueChanged<double>? onChange;
  final VoidCallback? onTap;
  @override
  State<DashboardTemperature> createState() => _DashboardTemperatureState();
}

class _DashboardTemperatureState extends State<DashboardTemperature> {
  Timer? _hide;
  bool _adjusting = false;
  double _start = 0, _distance = 0;
  bool get _enabled => widget.range != null && widget.onChange != null;
  double get _value =>
      widget.value ?? (widget.range!.minC + widget.range!.maxC) / 2;
  void _change(double value, {bool immediate = false}) {
    if (!_enabled) return;
    final next = widget.range!.snap(value);
    if (next != widget.value) {
      (immediate ? widget.onImmediate ?? widget.onChange : widget.onChange)
          ?.call(next);
    }
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
              onPressed: _enabled
                  ? () => _change(_value + widget.range!.stepC, immediate: true)
                  : null,
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
              onHorizontalDragStart: !_enabled
                  ? null
                  : (_) {
                      _start = _value;
                      _distance = 0;
                    },
              onHorizontalDragUpdate: !_enabled
                  ? null
                  : (e) {
                      _distance += e.delta.dx;
                      _change(_start + _distance / 32);
                    },
              child: Semantics(
                button: true,
                label:
                    '${widget.side} temperature${widget.pending ? ', pending' : ''}${widget.failure != null ? ', request failed' : ''}',
                value: widget.value == null
                    ? 'Unknown'
                    : '${widget.value!.toStringAsFixed(1)} degrees',
                onTap: widget.onTap,
                child: Center(
                  child: Text(
                    widget.value == null
                        ? '--'
                        : '${widget.value!.toStringAsFixed(1)}°',
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
              onPressed: _enabled
                  ? () => _change(_value - widget.range!.stepC, immediate: true)
                  : null,
              icon: Icon(Icons.arrow_drop_down, size: icon),
            ),
          ),
          SizedBox(
            height: 6,
            child: _adjusting && _enabled
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
                          left:
                              ((_value - widget.range!.minC) /
                                      (widget.range!.maxC -
                                          widget.range!.minC) *
                                      (bar.maxWidth - 4))
                                  .clamp(0, bar.maxWidth),
                          width: 4,
                          top: 0,
                          bottom: 0,
                          child: const ColoredBox(color: Colors.white),
                        ),
                        if (widget.pending)
                          const Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: LinearProgressIndicator(minHeight: 2),
                          ),
                      ],
                    ),
                  )
                : widget.pending
                ? const LinearProgressIndicator(minHeight: 2)
                : widget.failure != null
                ? Tooltip(
                    message: widget.failure!,
                    child: Container(
                      height: 2,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  )
                : const SizedBox(),
          ),
        ],
      );
    },
  );
}

class ClimateTemperatureControl extends StatelessWidget {
  const ClimateTemperatureControl({
    super.key,
    required this.service,
    required this.zone,
    required this.side,
    required this.scale,
    this.onTap,
  });
  final ClimateService? service;
  final String zone, side;
  final double scale;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => StreamBuilder<ClimateSnapshot>(
    stream: service?.changes,
    initialData: service?.current ?? ClimateSnapshot(),
    builder: (context, snapshot) {
      final state = snapshot.requireData;
      final range = state.available ? state.capabilities?.zones[zone] : null;
      final value = state.temperatures[zone] ?? const ClimateValue<double>();
      return Column(
        children: [
          if (state.simulated)
            const Text(
              'SIMULATION',
              style: TextStyle(fontSize: 9, letterSpacing: 1),
            ),
          Expanded(
            child: DashboardTemperature(
              side: side,
              value: value.displayed,
              range: range,
              pending: value.pending,
              failure: value.failure,
              onChange: range == null
                  ? null
                  : (v) => service!.requestTemperature(zone, v),
              onImmediate: range == null
                  ? null
                  : (v) =>
                        service!.requestTemperature(zone, v, immediate: true),
              onTap: range == null ? null : onTap,
              scale: scale,
            ),
          ),
        ],
      );
    },
  );
}
