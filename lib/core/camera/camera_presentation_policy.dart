import 'dart:async';

import '../vehicle/vehicle_data_service.dart';
import '../vehicle/vehicle_data_point.dart';
import '../vehicle/vehicle_signal.dart';
import 'camera_service.dart';

/// Normalized read-only inputs. Vehicle bundles supply mapping and authorization.
abstract final class CameraVehicleSignals {
  static final reverse = _boolean('vehicle.gear.reverse');
  static final pdc = _boolean('parking.pdc.active');
  static final left = _boolean('vehicle.indicators.left.active');
  static final right = _boolean('vehicle.indicators.right.active');
  static final speed = VehicleSignal<double>(
    key: 'vehicle.speed.mps',
    decode: (value) {
      if (value is num && value.isFinite && value >= 0) return value.toDouble();
      throw const FormatException(
        'vehicle.speed.mps requires finite nonnegative metres/second',
      );
    },
  );
  static final roadWheelAngle = VehicleSignal<double>(
    key: 'vehicle.steering.road_wheel_angle_rad',
    decode: (value) {
      if (value is num && value.isFinite && value.abs() <= 1.4) {
        return value.toDouble();
      }
      throw const FormatException(
        'Road-wheel angle requires finite radians; steering-wheel angle is not interchangeable',
      );
    },
  );
  static final pdcObservations = VehicleSignal<List<Map<String, dynamic>>>(
    key: 'parking.pdc.observations',
    decode: (value) {
      if (value is! List || value.length > 32) {
        throw const FormatException(
          'PDC requires at most32 measured observations',
        );
      }
      return value.map((entry) {
        if (entry is! Map ||
            entry['measured_vehicle_m'] is! List ||
            entry['region'] is! String) {
          throw const FormatException(
            'PDC needs measured vehicle coordinates and measured region',
          );
        }
        final point = entry['measured_vehicle_m'] as List;
        if (point.length != 3 ||
            point.any((v) => v is! num || !v.isFinite || v.abs() > 100)) {
          throw const FormatException('PDC point requires three finite metres');
        }
        return {
          'measured_vehicle_m': List<num>.from(point),
          'region': entry['region'],
          'provenance': entry['provenance'] ?? 'normalized_vehicle_measurement',
        };
      }).toList();
    },
  );
  static VehicleSignal<bool> _boolean(String key) => VehicleSignal<bool>(
    key: key,
    decode: (value) {
      if (value is bool) return value;
      throw FormatException('$key requires boolean');
    },
  );
}

class CameraSignalValue<T> {
  const CameraSignalValue(this.value, this.observed);
  final T value;
  final Duration observed;
  bool fresh(Duration now, Duration maxAge) =>
      now >= observed && now - observed <= maxAge;
}

class CameraPresentationRequest {
  const CameraPresentationRequest(this.owner, this.role);
  final String owner;
  final CameraRole role;
}

/// Deterministic precedence and hold policy independent of navigation and CAN.
final class CameraPresentationPolicy {
  CameraPresentationPolicy({
    this.sideViews = false,
    this.enabled = true,
    this.parkingSpeedMps = 3,
    this.speedHysteresisMps = 1,
    this.maxAge = const Duration(milliseconds: 750),
    this.hold = const Duration(milliseconds: 800),
  });
  final bool sideViews, enabled;
  final double parkingSpeedMps, speedHysteresisMps;
  final Duration maxAge, hold;
  CameraSignalValue<bool>? reverse, pdc, left, right;
  CameraSignalValue<double>? speed;
  CameraPresentationRequest? _active;
  Duration _lastCandidate = Duration.zero;
  String? _suppressed;
  bool _slow = false;
  void manualSelection() {
    _suppressed = _active?.owner;
    _active = null;
  }

  CameraPresentationRequest? evaluate(Duration now) {
    if (!enabled) {
      _active = null;
      return null;
    }
    bool yes(CameraSignalValue<bool>? signal) =>
        signal != null && signal.fresh(now, maxAge) && signal.value;
    final knownSpeed = speed != null && speed!.fresh(now, maxAge);
    _slow =
        knownSpeed &&
        speed!.value <= parkingSpeedMps + (_slow ? speedHysteresisMps : 0);
    CameraPresentationRequest? candidate;
    if (yes(reverse)) {
      candidate = const CameraPresentationRequest('reverse', CameraRole.rear);
    } else if (_slow && yes(pdc)) {
      candidate = const CameraPresentationRequest('pdc', CameraRole.front);
    } else if (_slow && sideViews && yes(left) != yes(right)) {
      candidate = yes(left)
          ? const CameraPresentationRequest('indicator_left', CameraRole.left)
          : const CameraPresentationRequest(
              'indicator_right',
              CameraRole.right,
            );
    }
    if (candidate?.owner != _suppressed) _suppressed = null;
    if (candidate?.owner == _suppressed && _suppressed != null) return null;
    if (candidate != null) {
      _active = candidate;
      _lastCandidate = now;
      return candidate;
    }
    // Expired/unknown signals cannot indefinitely renew a presentation request.
    // Hazards immediately end side requests instead of alternating left/right.
    if (_active?.owner.startsWith('indicator') == true &&
        yes(left) &&
        yes(right)) {
      _active = null;
      return null;
    }
    if (_active != null && now - _lastCandidate <= hold) return _active;
    _active = null;
    return null;
  }
}

/// Observed normalized values expire by source time and a local monotonic clock.
final class CameraPresentationService {
  CameraPresentationService(
    VehicleDataService vehicle, {
    CameraPresentationPolicy? policy,
  }) : policy = policy ?? CameraPresentationPolicy() {
    _watch(
      vehicle,
      CameraVehicleSignals.reverse,
      (value) => this.policy.reverse = value,
    );
    _watch(
      vehicle,
      CameraVehicleSignals.pdc,
      (value) => this.policy.pdc = value,
    );
    _watch(
      vehicle,
      CameraVehicleSignals.left,
      (value) => this.policy.left = value,
    );
    _watch(
      vehicle,
      CameraVehicleSignals.right,
      (value) => this.policy.right = value,
    );
    _watch(
      vehicle,
      CameraVehicleSignals.speed,
      (value) => this.policy.speed = value,
    );
    _watch(
      vehicle,
      CameraVehicleSignals.roadWheelAngle,
      (value) => _steering = value,
    );
    _watch(
      vehicle,
      CameraVehicleSignals.pdcObservations,
      (value) => _pdc = value,
    );
    _timer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => _evaluate(),
    );
  }
  final CameraPresentationPolicy policy;
  CameraSignalValue<double>? _steering;
  CameraSignalValue<List<Map<String, dynamic>>>? _pdc;
  Map<String, dynamic> get renderingMeasurements {
    const age = Duration(milliseconds: 250);
    final now = _clock.elapsed;
    return {
      if (policy.reverse?.fresh(now, age) == true)
        'reverse': policy.reverse!.value,
      if (_steering?.fresh(now, age) == true)
        'steering': {
          'road_wheel_angle_rad': _steering!.value,
          'age_ns': (now - _steering!.observed).inMicroseconds * 1000,
        },
      if (_pdc?.fresh(now, age) == true)
        'pdc': {
          'observations': _pdc!.value,
          'age_ns': (now - _pdc!.observed).inMicroseconds * 1000,
        },
    };
  }

  final _clock = Stopwatch()..start();
  final _subscriptions = <StreamSubscription<Object?>>[];
  final _events = StreamController<CameraPresentationRequest?>.broadcast(
    sync: true,
  );
  final _sequences = <String, int>{};
  Timer? _timer;
  CameraPresentationRequest? current;
  Stream<CameraPresentationRequest?> get changes => _events.stream;
  void _watch<T>(
    VehicleDataService vehicle,
    VehicleSignal<T> signal,
    void Function(CameraSignalValue<T>) accept,
  ) {
    _subscriptions.add(
      vehicle.watch(signal, emitCurrent: true).listen((
        VehicleDataPoint<T> point,
      ) {
        if (point.sequence <= (_sequences[point.key] ?? -1)) return;
        _sequences[point.key] = point.sequence;
        final sourceAge = DateTime.now().difference(point.timestamp);
        if (sourceAge.isNegative || sourceAge > policy.maxAge) return;
        accept(CameraSignalValue(point.value, _clock.elapsed - sourceAge));
        _evaluate();
      }),
    );
  }

  void _evaluate() {
    final next = policy.evaluate(_clock.elapsed);
    if (next?.owner == current?.owner && next?.role == current?.role) return;
    current = next;
    _events.add(next);
  }

  void manualSelection() {
    policy.manualSelection();
    current = null;
  }

  Future<void> close() async {
    _timer?.cancel();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    // Presentation subscribers do not own service shutdown; a paused listener
    // may consume its done event later. Closing the controller is synchronous.
    unawaited(_events.close());
  }
}
