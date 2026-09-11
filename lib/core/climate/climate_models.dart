typedef ClimateZoneId = String;

class ClimateRange {
  ClimateRange(this.min, this.max, this.step) {
    if (!min.isFinite ||
        !max.isFinite ||
        !step.isFinite ||
        min >= max ||
        !(max - min).isFinite ||
        !((max - min) / step).isFinite ||
        step <= 0 ||
        step > max - min) {
      throw ArgumentError('Invalid climate range');
    }
  }
  final double min, max, step;
  bool contains(double value) =>
      value.isFinite &&
      value >= min &&
      value <= max &&
      (((value - min) / step) - ((value - min) / step).round()).abs() < 1e-6;
  double snap(double value) =>
      min +
      ((value - min) / step).round().clamp(
            0,
            ((max - min) / step + 1e-9).floor(),
          ) *
          step;
}

class ClimateTemperatureRange extends ClimateRange {
  ClimateTemperatureRange(super.minC, super.maxC, super.stepC);
  double get minC => min;
  double get maxC => max;
  double get stepC => step;
}

class ClimateCapabilities {
  ClimateCapabilities({
    required Map<ClimateZoneId, ClimateTemperatureRange> zones,
    this.fan,
    this.acSupported = false,
  }) : zones = Map.unmodifiable(zones) {
    if (zones.length > 8 ||
        zones.keys.any(
          (id) => !RegExp(r'^[a-z][a-z0-9_]{0,31}$').hasMatch(id),
        )) {
      throw ArgumentError('Invalid climate zone IDs');
    }
  }
  final Map<ClimateZoneId, ClimateTemperatureRange> zones;
  final ClimateRange? fan;
  final bool acSupported;
  bool get usable => zones.isNotEmpty || fan != null || acSupported;

  static ClimateCapabilities parse(Object? value) {
    if (value is! Map<String, Object?>) {
      throw const FormatException('climate must be an object');
    }
    ClimateTemperatureRange range(
      Object? raw,
      String min,
      String max,
      String step,
    ) {
      if (raw is! Map<String, Object?> ||
          raw[min] is! num ||
          raw[max] is! num ||
          raw[step] is! num) {
        throw const FormatException(
          'Climate range requires numeric min/max/step',
        );
      }
      return ClimateTemperatureRange(
        (raw[min] as num).toDouble(),
        (raw[max] as num).toDouble(),
        (raw[step] as num).toDouble(),
      );
    }

    final zones = value['zones'] ?? <String, Object?>{};
    final features = value['features'] ?? <Object?>[];
    if (zones is! Map<String, Object?> ||
        features is! List ||
        features.any((v) => v != 'ac') ||
        features.toSet().length != features.length) {
      throw const FormatException('Invalid climate zones/features');
    }
    return ClimateCapabilities(
      zones: {
        for (final e in zones.entries)
          e.key: range(e.value, 'minC', 'maxC', 'stepC'),
      },
      fan: value.containsKey('fan')
          ? range(value['fan'], 'min', 'max', 'step')
          : null,
      acSupported: features.contains('ac'),
    );
  }

  static ClimateCapabilities simulation() => ClimateCapabilities(
    zones: {
      for (final zone in ['front_left', 'front_right'])
        zone: ClimateTemperatureRange(18, 26, .5),
    },
    fan: ClimateRange(0, 5, 1),
    acSupported: true,
  );
}

class ClimateValue<T> {
  const ClimateValue({
    this.confirmed,
    this.requested,
    this.pending = false,
    this.failure,
  });
  final T? confirmed, requested;
  final bool pending;
  final String? failure;
  T? get displayed => pending ? requested : confirmed;
}

class ClimateSnapshot {
  ClimateSnapshot({
    this.capabilities,
    this.available = false,
    this.simulated = false,
    Map<ClimateZoneId, ClimateValue<double>> temperatures = const {},
    this.fan = const ClimateValue(),
    this.ac = const ClimateValue(),
  }) : temperatures = Map.unmodifiable(temperatures);
  final ClimateCapabilities? capabilities;
  final bool available, simulated;
  final Map<ClimateZoneId, ClimateValue<double>> temperatures;
  final ClimateValue<double> fan;
  final ClimateValue<bool> ac;
}
