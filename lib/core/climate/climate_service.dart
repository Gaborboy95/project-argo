import 'dart:async';

import '../diagnostics/diagnostics_service.dart';
import '../vehicle/vehicle_data_service.dart';
import '../vehicle/vehicle_data_point.dart';
import '../vehicle/vehicle_signal.dart';
import 'climate_models.dart';
export 'climate_models.dart';

abstract interface class ClimateService {
  ClimateSnapshot get current;
  Stream<ClimateSnapshot> get changes;
  void requestTemperature(
    ClimateZoneId zone,
    double value, {
    bool immediate = false,
  });
  void requestFanLevel(double value);
  void requestAc(bool enabled);
  Future<void> close();
}

/// No production confirmation is inferred from a command or elapsed time.
class VehicleClimateService implements ClimateService {
  VehicleClimateService({
    required this.capabilities,
    required this.publish,
    required this.authorize,
    required this.diagnostics,
    VehicleDataService? vehicle,
    this.simulated = false,
    this.timer = Timer.new,
  }) {
    for (final key in keys) {
      if (vehicle != null) {
        _subscriptions.add(
          vehicle
              .watch(VehicleSignal<Object?>(key: key, decode: (v) => v))
              .listen(
                (point) => unawaited(_feedback(point)),
                onError: (Object _) => _reject(key),
              ),
        );
      }
    }
  }
  static const requestTopic = 'vehicle.climate.request.v1';
  static const confirmationTimeout = Duration(seconds: 3);
  static const temperatureDebounce = Duration(milliseconds: 100);
  final ClimateCapabilities? capabilities;
  final bool simulated;
  final Future<void> Function(Map<String, Object> payload) publish;
  final Future<bool> Function(String pluginId) authorize;
  final DiagnosticsService diagnostics;
  final Timer Function(Duration, void Function()) timer;
  final _events = StreamController<ClimateSnapshot>.broadcast(sync: true);
  final List<StreamSubscription<VehicleDataPoint<Object?>>> _subscriptions = [];
  final Map<String, ClimateValue<Object>> _values = {};
  final Map<String, Timer> _debounce = {}, _deadlines = {};
  final Map<String, int> _serials = {}, _sent = {}, _sequences = {};
  final Set<String> _rejected = {};
  bool _closed = false, _available = false;
  int _epoch = 0;
  Iterable<String> get keys => [
    for (final zone in capabilities?.zones.keys ?? <String>[])
      'climate.$zone.target_temperature_c',
    if (capabilities?.fan != null) 'climate.fan.level',
    if (capabilities?.acSupported == true) 'climate.ac.enabled',
  ];
  ClimateValue<T> _value<T>(String key) {
    final v = _values[key];
    return ClimateValue(
      confirmed: v?.confirmed as T?,
      requested: v?.requested as T?,
      pending: v?.pending ?? false,
      failure: v?.failure,
    );
  }

  @override
  ClimateSnapshot get current => ClimateSnapshot(
    capabilities: capabilities,
    available: _available && !_closed,
    simulated: simulated,
    temperatures: {
      for (final zone in capabilities?.zones.keys ?? <String>[])
        zone: _value<double>('climate.$zone.target_temperature_c'),
    },
    fan: _value<double>('climate.fan.level'),
    ac: _value<bool>('climate.ac.enabled'),
  );
  @override
  Stream<ClimateSnapshot> get changes => _events.stream;
  void _emit() {
    if (!_closed) _events.add(current);
  }

  /// An integration unload/replacement invalidates both state and in-flight authorization.
  void invalidate({bool available = false}) {
    _epoch++;
    for (final t in [..._debounce.values, ..._deadlines.values]) {
      t.cancel();
    }
    _debounce.clear();
    _deadlines.clear();
    _values.clear();
    _serials.clear();
    _sent.clear();
    _sequences.clear();
    _available = available && capabilities?.usable == true;
    _emit();
  }

  void _reject(String key) {
    if (_rejected.add(key)) {
      diagnostics.warning(
        'climate.feedback',
        'Rejected invalid or unauthorized climate feedback for $key.',
      );
    }
  }

  Object? _validated(String key, Object? raw) {
    if (key == 'climate.ac.enabled') {
      return capabilities?.acSupported == true && raw is bool ? raw : null;
    }
    if (raw is! num) return null;
    final range = key == 'climate.fan.level'
        ? capabilities?.fan
        : capabilities?.zones[key.split('.')[1]];
    final value = raw.toDouble();
    return range?.contains(value) == true ? range!.snap(value) : null;
  }

  Future<void> _feedback(VehicleDataPoint<Object?> point) async {
    final epoch = _epoch, serial = _serials[point.key];
    if (_closed || !_available) return;
    bool allowed = false;
    try {
      allowed = point.sourceId != null && await authorize(point.sourceId!);
    } on Object {
      /* fail closed */
    }
    if (_closed || epoch != _epoch) return;
    final value = _validated(point.key, point.value);
    if (!allowed || value == null) {
      _reject(point.key);
      return;
    }
    if (point.sequence <= (_sequences[point.key] ?? -1)) return;
    _sequences[point.key] = point.sequence;
    final old = _values[point.key] ?? const ClimateValue<Object>();
    final matched =
        old.requested != null &&
        old.requested == value &&
        serial == _serials[point.key] &&
        _sent[point.key] == serial;
    if (matched) {
      _deadlines.remove(point.key)?.cancel();
    }
    _values[point.key] = ClimateValue(
      confirmed: value,
      requested: old.requested,
      pending: old.pending && !matched,
      failure: matched ? null : old.failure,
    );
    _emit();
  }

  @override
  void requestTemperature(
    String zone,
    double value, {
    bool immediate = false,
  }) => _request('climate.$zone.target_temperature_c', value, {
    'operation': 'set_temperature',
    'zone': zone,
    'valueC': value,
  }, debounce: !immediate);
  @override
  void requestFanLevel(double value) => _request('climate.fan.level', value, {
    'operation': 'set_fan_level',
    'value': value,
  });
  @override
  void requestAc(bool enabled) => _request('climate.ac.enabled', enabled, {
    'operation': 'set_ac',
    'value': enabled,
  });
  void _request(
    String key,
    Object value,
    Map<String, Object> payload, {
    bool debounce = false,
  }) {
    if (_closed || !_available) return;
    final validated = _validated(key, value);
    if (!keys.contains(key) || validated == null) {
      throw ArgumentError('Unsupported climate request');
    }
    value = validated;
    payload = {
      ...payload,
      if (payload.containsKey('valueC')) 'valueC': value else 'value': value,
    };
    final serial = (_serials[key] ?? 0) + 1, epoch = _epoch;
    _serials[key] = serial;
    _debounce.remove(key)?.cancel();
    _deadlines.remove(key)?.cancel();
    _values[key] = ClimateValue(
      confirmed: _values[key]?.confirmed,
      requested: value,
      pending: true,
    );
    _deadlines[key] = timer(
      confirmationTimeout,
      () => _fail(key, serial, epoch, 'Vehicle confirmation timed out'),
    );
    _emit();
    void send() {
      if (_closed ||
          epoch != _epoch ||
          serial != _serials[key] ||
          _values[key]?.pending != true) {
        return;
      }
      _debounce.remove(key);
      _sent[key] = serial;
      unawaited(() async {
        try {
          await publish(payload);
          if (simulated &&
              !_closed &&
              epoch == _epoch &&
              serial == _serials[key]) {
            await _feedback(
              VehicleDataPoint(
                key: key,
                value: value,
                timestamp: DateTime.now(),
                sequence: serial,
                sourceId: 'argo.simulation',
              ),
            );
          }
        } on Object {
          _fail(key, serial, epoch, 'Climate command unavailable');
        }
      }());
    }

    if (debounce) {
      _debounce[key] = timer(temperatureDebounce, send);
    } else {
      send();
    }
  }

  void _fail(String key, int serial, int epoch, String failure) {
    if (_closed ||
        epoch != _epoch ||
        serial != _serials[key] ||
        _values[key]?.pending != true) {
      return;
    }
    _deadlines.remove(key)?.cancel();
    _debounce.remove(key)?.cancel();
    _values[key] = ClimateValue(
      confirmed: _values[key]?.confirmed,
      requested: _values[key]?.requested,
      failure: failure,
    );
    _emit();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    invalidate();
    _closed = true;
    for (final s in _subscriptions) {
      await s.cancel();
    }
    await _events.close();
  }
}
