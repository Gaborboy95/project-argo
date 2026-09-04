import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/vehicle/vehicle_data_point.dart';
import '../../core/vehicle/vehicle_data_service.dart';
import '../../core/vehicle/vehicle_signals.dart';

class VehiclePage extends StatefulWidget {
  const VehiclePage({super.key, required this.vehicleData});

  final VehicleDataService vehicleData;

  @override
  State<VehiclePage> createState() => _VehiclePageState();
}

class _VehiclePageState extends State<VehiclePage> {
  VehicleDataPoint<double>? _engineRpm;
  StreamSubscription<VehicleDataPoint<double>>? _rpmSubscription;
  var _subscriptionGeneration = 0;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(VehiclePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.vehicleData, oldWidget.vehicleData)) {
      unawaited(_rpmSubscription?.cancel());
      _subscribe();
    }
  }

  void _subscribe() {
    final generation = ++_subscriptionGeneration;
    try {
      _engineRpm = widget.vehicleData.current(VehicleSignals.engineRpm);
    } on Object {
      _engineRpm = null;
    }
    _rpmSubscription = widget.vehicleData
        .watch(VehicleSignals.engineRpm, emitCurrent: true)
        .listen(
          (point) {
            if (!mounted || generation != _subscriptionGeneration) return;
            setState(() => _engineRpm = point);
          },
          onError: (Object _, StackTrace _) {
            if (!mounted || generation != _subscriptionGeneration) return;
            setState(() => _engineRpm = null);
          },
        );
  }

  @override
  void dispose() {
    _subscriptionGeneration++;
    unawaited(_rpmSubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rpm = _engineRpm?.value;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.directions_car_outlined, size: 56),
            const SizedBox(height: 16),
            Text('Vehicle', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 24),
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 24,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Engine speed',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      rpm == null ? '—' : _formatRpm(rpm),
                      style: Theme.of(context).textTheme.headlineLarge,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _formatRpm(double rpm) {
    return rpm == rpm.roundToDouble()
        ? '${rpm.toInt()} RPM'
        : '${rpm.toStringAsFixed(1)} RPM';
  }
}
