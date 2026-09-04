import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/power/head_unit_power_service.dart';
import '../../core/power/head_unit_power_snapshot.dart';
import '../../core/vehicle/vehicle_data_point.dart';
import '../../core/vehicle/vehicle_data_service.dart';
import '../../core/vehicle/vehicle_signals.dart';

class VehiclePage extends StatefulWidget {
  const VehiclePage({
    super.key,
    required this.vehicleData,
    required this.power,
  });

  final VehicleDataService vehicleData;
  final HeadUnitPowerService power;

  @override
  State<VehiclePage> createState() => _VehiclePageState();
}

class _VehiclePageState extends State<VehiclePage> {
  VehicleDataPoint<double>? _engineRpm;
  late HeadUnitPowerSnapshot _powerSnapshot;
  StreamSubscription<VehicleDataPoint<double>>? _rpmSubscription;
  StreamSubscription<HeadUnitPowerSnapshot>? _powerSubscription;
  var _subscriptionGeneration = 0;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(VehiclePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.vehicleData, oldWidget.vehicleData) ||
        !identical(widget.power, oldWidget.power)) {
      unawaited(_rpmSubscription?.cancel());
      unawaited(_powerSubscription?.cancel());
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
    _powerSnapshot = widget.power.current;
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
    _powerSubscription = widget.power.changes.listen((snapshot) {
      if (!mounted || generation != _subscriptionGeneration) return;
      setState(() => _powerSnapshot = snapshot);
    });
  }

  @override
  void dispose() {
    _subscriptionGeneration++;
    unawaited(_rpmSubscription?.cancel());
    unawaited(_powerSubscription?.cancel());
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
                      key: const ValueKey('vehicle.engineRpm'),
                      style: Theme.of(context).textTheme.headlineLarge,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 16,
                ),
                child: Column(
                  children: [
                    _PowerValueRow(
                      label: 'Vehicle power',
                      value: _powerSnapshot.vehiclePowerState.wireValue,
                    ),
                    _PowerValueRow(
                      label: 'Ignition',
                      value: _powerSnapshot.ignitionState?.wireValue ?? '—',
                    ),
                    _PowerValueRow(
                      label: 'Battery voltage',
                      value: _powerSnapshot.batteryVoltage == null
                          ? '—'
                          : '${_powerSnapshot.batteryVoltage!.toStringAsFixed(1)} V',
                    ),
                    _PowerValueRow(
                      label: 'Head-unit state',
                      value: _powerSnapshot.operationalState.wireValue,
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

class _PowerValueRow extends StatelessWidget {
  const _PowerValueRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label: ', style: Theme.of(context).textTheme.bodyMedium),
        Text(value, style: Theme.of(context).textTheme.bodyLarge),
      ],
    ),
  );
}
