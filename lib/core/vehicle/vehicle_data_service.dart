import 'dart:async';

import 'vehicle_data_point.dart';
import 'vehicle_signal.dart';

/// Application-facing access to normalized vehicle signals.
abstract interface class VehicleDataService {
  VehicleDataPoint<T>? current<T>(VehicleSignal<T> signal);

  Stream<VehicleDataPoint<T>> watch<T>(
    VehicleSignal<T> signal, {
    bool emitCurrent = false,
  });

  /// A read-through raw snapshot for diagnostics and generic tooling.
  Map<String, VehicleDataPoint<Object?>> get snapshot;
}
