import 'dart:async';

import '../vehicle/vehicle_data_point.dart';
import '../vehicle/vehicle_data_service.dart';
import '../vehicle/vehicle_ignition_state.dart';
import '../vehicle/vehicle_power_state.dart';
import '../vehicle/vehicle_signals.dart';
import 'head_unit_power_service.dart';
import 'head_unit_power_snapshot.dart';

typedef VehiclePowerStateChanged = void Function(
  VehiclePowerState previous,
  VehiclePowerState current,
);
typedef HeadUnitPowerErrorHandler = void Function(
  Object error,
  StackTrace stackTrace,
);

/// Combines normalized [VehicleDataService] signals into one current snapshot.
final class VehicleDataHeadUnitPowerService implements HeadUnitPowerService {
  factory VehicleDataHeadUnitPowerService({
    required VehicleDataService vehicleData,
    VehiclePowerStateChanged? onVehiclePowerStateChanged,
    HeadUnitPowerErrorHandler? onError,
  }) => VehicleDataHeadUnitPowerService._(
    vehicleData,
    onVehiclePowerStateChanged,
    onError,
  );

  VehicleDataHeadUnitPowerService._(
    this._vehicleData,
    this._onVehiclePowerStateChanged,
    this._onError,
  ) {
    _seedCurrentValues();
    _subscriptions.addAll([
      _vehicleData
          .watch(VehicleSignals.vehiclePowerState)
          .listen(_updatePowerState, onError: _handleStreamError),
      _vehicleData
          .watch(VehicleSignals.vehicleIgnitionState)
          .listen(_updateIgnitionState, onError: _handleStreamError),
      _vehicleData
          .watch(VehicleSignals.vehicleBatteryVoltage)
          .listen(_updateBatteryVoltage, onError: _handleStreamError),
    ]);
  }

  final VehicleDataService _vehicleData;
  final VehiclePowerStateChanged? _onVehiclePowerStateChanged;
  final HeadUnitPowerErrorHandler? _onError;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  final StreamController<HeadUnitPowerSnapshot> _changes =
      StreamController<HeadUnitPowerSnapshot>.broadcast(sync: true);

  HeadUnitPowerSnapshot _current = const HeadUnitPowerSnapshot();
  Future<void>? _closeFuture;

  @override
  HeadUnitPowerSnapshot get current => _current;

  @override
  Stream<HeadUnitPowerSnapshot> get changes => _changes.stream;

  void _seedCurrentValues() {
    try {
      final point = _vehicleData.current(VehicleSignals.vehiclePowerState);
      if (point != null) _updatePowerState(point);
    } on Object catch (error, stackTrace) {
      _reportError(error, stackTrace);
    }
    try {
      final point = _vehicleData.current(VehicleSignals.vehicleIgnitionState);
      if (point != null) _updateIgnitionState(point);
    } on Object catch (error, stackTrace) {
      _reportError(error, stackTrace);
    }
    try {
      final point = _vehicleData.current(VehicleSignals.vehicleBatteryVoltage);
      if (point != null) _updateBatteryVoltage(point);
    } on Object catch (error, stackTrace) {
      _reportError(error, stackTrace);
    }
  }

  void _updatePowerState(VehicleDataPoint<VehiclePowerState> point) {
    if (_closeFuture != null || point.value == _current.vehiclePowerState) {
      return;
    }
    final previous = _current.vehiclePowerState;
    _emit(
      HeadUnitPowerSnapshot(
        vehiclePowerState: point.value,
        ignitionState: _current.ignitionState,
        batteryVoltage: _current.batteryVoltage,
        updatedAt: point.timestamp,
      ),
    );
    try {
      _onVehiclePowerStateChanged?.call(previous, point.value);
    } on Object catch (error, stackTrace) {
      _reportError(error, stackTrace);
    }
  }

  void _updateIgnitionState(VehicleDataPoint<VehicleIgnitionState> point) {
    if (_closeFuture != null || point.value == _current.ignitionState) return;
    _emit(
      HeadUnitPowerSnapshot(
        vehiclePowerState: _current.vehiclePowerState,
        ignitionState: point.value,
        batteryVoltage: _current.batteryVoltage,
        updatedAt: point.timestamp,
      ),
    );
  }

  void _updateBatteryVoltage(VehicleDataPoint<double> point) {
    if (_closeFuture != null || point.value == _current.batteryVoltage) return;
    _emit(
      HeadUnitPowerSnapshot(
        vehiclePowerState: _current.vehiclePowerState,
        ignitionState: _current.ignitionState,
        batteryVoltage: point.value,
        updatedAt: point.timestamp,
      ),
    );
  }

  void _emit(HeadUnitPowerSnapshot snapshot) {
    _current = snapshot;
    _changes.add(snapshot);
  }

  void _handleStreamError(Object error, StackTrace stackTrace) {
    _reportError(error, stackTrace);
  }

  void _reportError(Object error, StackTrace stackTrace) {
    try {
      _onError?.call(error, stackTrace);
    } on Object {
      // A diagnostic callback must not break normalized state processing.
    }
  }

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    Object? firstError;
    StackTrace? firstStackTrace;
    for (final subscription in _subscriptions) {
      try {
        await subscription.cancel();
      } on Object catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    _subscriptions.clear();
    try {
      await _changes.close();
    } on Object catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    if (firstError case final error?) {
      Error.throwWithStackTrace(error, firstStackTrace!);
    }
  }
}
