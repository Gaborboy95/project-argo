import 'dart:async';

import 'package:argo/core/power/head_unit_operational_state.dart';
import 'package:argo/core/power/vehicle_data_head_unit_power_service.dart';
import 'package:argo/core/vehicle/vehicle_data_point.dart';
import 'package:argo/core/vehicle/vehicle_data_service.dart';
import 'package:argo/core/vehicle/vehicle_ignition_state.dart';
import 'package:argo/core/vehicle/vehicle_power_state.dart';
import 'package:argo/core/vehicle/vehicle_signal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _TestVehicleDataService vehicleData;
  late VehicleDataHeadUnitPowerService power;

  setUp(() {
    vehicleData = _TestVehicleDataService();
    power = VehicleDataHeadUnitPowerService(vehicleData: vehicleData);
  });

  tearDown(() async {
    await power.close();
    await vehicleData.close();
  });

  test('starts unknown with optional values unavailable', () {
    expect(power.current.vehiclePowerState, VehiclePowerState.unknown);
    expect(power.current.ignitionState, isNull);
    expect(power.current.batteryVoltage, isNull);
    expect(power.current.updatedAt, isNull);
    expect(power.current.operationalState, HeadUnitOperationalState.unknown);
  });

  test('emits vehicle power state updates', () {
    final snapshots = <VehiclePowerState>[];
    power.changes.listen(
      (snapshot) => snapshots.add(snapshot.vehiclePowerState),
    );

    vehicleData.publish('vehicle.power.state', 'awake');
    vehicleData.publish('vehicle.power.state', 'active');

    expect(snapshots, [VehiclePowerState.awake, VehiclePowerState.active]);
    expect(power.current.vehiclePowerState, VehiclePowerState.active);
  });

  test('updates ignition independently and preserves vehicle power', () {
    vehicleData.publish('vehicle.power.state', 'awake');
    vehicleData.publish('vehicle.ignition.state', 'accessory');

    expect(power.current.vehiclePowerState, VehiclePowerState.awake);
    expect(power.current.ignitionState, VehicleIgnitionState.accessory);
    expect(power.current.batteryVoltage, isNull);
  });

  test('updates battery voltage independently and preserves ignition', () {
    vehicleData.publish('vehicle.ignition.state', 'on');
    vehicleData.publish('vehicle.battery.voltage', 12);
    expect(power.current.batteryVoltage, 12.0);

    vehicleData.publish('vehicle.battery.voltage', 13.8);

    expect(power.current.vehiclePowerState, VehiclePowerState.unknown);
    expect(power.current.ignitionState, VehicleIgnitionState.on);
    expect(power.current.batteryVoltage, 13.8);
  });

  test('suppresses duplicate semantic snapshots', () {
    final snapshots = <Object?>[];
    power.changes.listen(snapshots.add);
    final firstTimestamp = DateTime.utc(2026, 9, 4, 10);

    vehicleData.publish(
      'vehicle.power.state',
      'awake',
      timestamp: firstTimestamp,
    );
    vehicleData.publish(
      'vehicle.power.state',
      'awake',
      timestamp: firstTimestamp.add(const Duration(seconds: 1)),
    );

    expect(snapshots, hasLength(1));
    expect(power.current.updatedAt, firstTimestamp);
  });

  test('requests catch-up values without duplicating seeded state', () async {
    await power.close();
    vehicleData.emitCurrentRequests.clear();
    vehicleData.publish('vehicle.power.state', 'awake');
    final transitions = <String>[];

    power = VehicleDataHeadUnitPowerService(
      vehicleData: vehicleData,
      onVehiclePowerStateChanged: (previous, current) {
        transitions.add('${previous.wireValue}->${current.wireValue}');
      },
    );
    final snapshots = <Object?>[];
    power.changes.listen(snapshots.add);

    expect(power.current.vehiclePowerState, VehiclePowerState.awake);
    expect(vehicleData.emitCurrentRequests, {
      'vehicle.power.state',
      'vehicle.ignition.state',
      'vehicle.battery.voltage',
    });
    await Future<void>.delayed(Duration.zero);

    expect(transitions, ['unknown->awake']);
    expect(snapshots, isEmpty);
  });

  test('catches a value changed between seeding and subscription', () async {
    await power.close();
    vehicleData.publish('vehicle.power.state', 'asleep');
    vehicleData.beforeWatch = (key) {
      if (key != 'vehicle.power.state') return;
      vehicleData.beforeWatch = null;
      vehicleData.publish('vehicle.power.state', 'awake');
    };

    power = VehicleDataHeadUnitPowerService(vehicleData: vehicleData);

    expect(power.current.vehiclePowerState, VehiclePowerState.asleep);
    await Future<void>.delayed(Duration.zero);
    expect(power.current.vehiclePowerState, VehiclePowerState.awake);
  });

  test('retains the most recent valid state after a decoding error', () async {
    await power.close();
    final errors = <Object>[];
    power = VehicleDataHeadUnitPowerService(
      vehicleData: vehicleData,
      onError: (error, _) => errors.add(error),
    );
    vehicleData.publish('vehicle.power.state', 'awake');

    vehicleData.publish('vehicle.power.state', 'not-a-state');

    expect(power.current.vehiclePowerState, VehiclePowerState.awake);
    expect(errors, hasLength(1));
    expect(errors.single, isA<FormatException>());
  });

  test('cancels all vehicle signal subscriptions on close', () async {
    expect(vehicleData.activeSubscriptions, 3);

    await power.close();

    expect(vehicleData.activeSubscriptions, 0);
    vehicleData.publish('vehicle.power.state', 'active');
    expect(power.current.vehiclePowerState, VehiclePowerState.unknown);
  });

  test('maps normalized vehicle power to head-unit operational state', () {
    expect(
      HeadUnitOperationalState.fromVehiclePowerState(VehiclePowerState.asleep),
      HeadUnitOperationalState.standby,
    );
    expect(
      HeadUnitOperationalState.fromVehiclePowerState(VehiclePowerState.awake),
      HeadUnitOperationalState.awake,
    );
    expect(
      HeadUnitOperationalState.fromVehiclePowerState(VehiclePowerState.active),
      HeadUnitOperationalState.awake,
    );
  });
}

final class _TestVehicleDataService implements VehicleDataService {
  final Map<String, VehicleDataPoint<Object?>> _current = {};
  final Map<String, StreamController<VehicleDataPoint<Object?>>> _controllers =
      {};
  var _sequence = 0;
  var activeSubscriptions = 0;
  final Set<String> emitCurrentRequests = {};
  void Function(String key)? beforeWatch;

  @override
  VehicleDataPoint<T>? current<T>(VehicleSignal<T> signal) {
    final point = _current[signal.key];
    return point == null ? null : _decode(point, signal);
  }

  @override
  Map<String, VehicleDataPoint<Object?>> get snapshot =>
      Map.unmodifiable(_current);

  @override
  Stream<VehicleDataPoint<T>> watch<T>(
    VehicleSignal<T> signal, {
    bool emitCurrent = false,
  }) {
    if (emitCurrent) emitCurrentRequests.add(signal.key);
    beforeWatch?.call(signal.key);
    final source = _controller(signal.key).stream
        .map((point) => _decode(point, signal));
    final retained = current(signal);
    if (!emitCurrent || retained == null) return source;
    return (() async* {
      yield retained;
      yield* source;
    })();
  }

  void publish(String key, Object? value, {DateTime? timestamp}) {
    final sequence = ++_sequence;
    final point = VehicleDataPoint<Object?>(
      key: key,
      value: value,
      timestamp: timestamp ?? DateTime.utc(2026, 9, 4, 10, 0, sequence),
      sequence: sequence,
      sourceId: 'test.vehicle',
    );
    _current[key] = point;
    _controller(key).add(point);
  }

  Future<void> close() async {
    for (final controller in _controllers.values) {
      await controller.close();
    }
  }

  StreamController<VehicleDataPoint<Object?>> _controller(String key) =>
      _controllers.putIfAbsent(
        key,
        () => StreamController<VehicleDataPoint<Object?>>.broadcast(
          sync: true,
          onListen: () => activeSubscriptions++,
          onCancel: () => activeSubscriptions--,
        ),
      );

  static VehicleDataPoint<T> _decode<T>(
    VehicleDataPoint<Object?> point,
    VehicleSignal<T> signal,
  ) => VehicleDataPoint<T>(
    key: point.key,
    value: signal.decode(point.value),
    timestamp: point.timestamp,
    sequence: point.sequence,
    sourceId: point.sourceId,
  );
}
