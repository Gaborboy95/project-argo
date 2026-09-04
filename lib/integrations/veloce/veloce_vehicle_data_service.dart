import 'dart:async';

import 'package:veloce_lua_core/veloce_lua_core.dart' as veloce;

import '../../core/vehicle/vehicle_data_point.dart';
import '../../core/vehicle/vehicle_data_service.dart';
import '../../core/vehicle/vehicle_signal.dart';

/// Read-through adapter from Veloce's bus to Argo's vehicle-data contract.
final class VeloceVehicleDataService implements VehicleDataService {
  VeloceVehicleDataService(this._vehicleDataBus);

  final veloce.VehicleDataBus _vehicleDataBus;
  var _nextSubscriptionId = 1;

  @override
  VehicleDataPoint<T>? current<T>(VehicleSignal<T> signal) {
    final point = _vehicleDataBus.valueFor(signal.key);
    return point == null ? null : _translate(point, signal.decode);
  }

  @override
  Map<String, VehicleDataPoint<Object?>> get snapshot => Map.unmodifiable({
    for (final entry in _vehicleDataBus.latest.entries)
      entry.key: _translate<Object?>(entry.value, (value) => value),
  });

  @override
  Stream<VehicleDataPoint<T>> watch<T>(
    VehicleSignal<T> signal, {
    bool emitCurrent = false,
  }) {
    late final StreamController<VehicleDataPoint<T>> controller;
    veloce.VehicleDataSubscription? subscription;
    var cancelled = false;

    controller = StreamController<VehicleDataPoint<T>>(
      sync: true,
      onListen: () {
        if (cancelled) return;
        try {
          final createdSubscription = _vehicleDataBus.subscribe(
            ownerId: 'argo.vehicle-data.${_nextSubscriptionId++}',
            key: signal.key,
            emitCurrent: emitCurrent,
            handler: (point) {
              if (cancelled || controller.isClosed) return;
              try {
                controller.add(_translate(point, signal.decode));
              } on Object catch (error, stackTrace) {
                controller.addError(error, stackTrace);
              }
            },
          );
          subscription = createdSubscription;
          if (cancelled) {
            subscription = null;
            unawaited(createdSubscription.cancel());
          }
        } on Object catch (error, stackTrace) {
          controller.addError(error, stackTrace);
          unawaited(controller.close());
        }
      },
      onCancel: () async {
        cancelled = true;
        final activeSubscription = subscription;
        subscription = null;
        await activeSubscription?.cancel();
      },
    );
    return controller.stream;
  }

  static VehicleDataPoint<T> _translate<T>(
    veloce.VehicleDataPoint point,
    T Function(Object? value) decode,
  ) => VehicleDataPoint<T>(
    key: point.key,
    value: decode(point.value),
    timestamp: point.timestamp,
    sequence: point.sequence,
    sourceId: point.sourcePluginId,
  );
}
