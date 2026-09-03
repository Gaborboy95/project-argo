import 'dart:convert';
import 'dart:io';

import 'package:veloce_lua_core/veloce_lua_core.dart';

const simulationScenarioSchemaVersion = 1;

sealed class SimulationScenarioEvent {
  SimulationScenarioEvent({required this.atMs}) {
    if (atMs < 0) {
      throw ArgumentError.value(atMs, 'atMs', 'Must not be negative');
    }
  }

  final int atMs;
}

final class SimulationCanEvent extends SimulationScenarioEvent {
  SimulationCanEvent({required super.atMs, required this.frame});

  final CanFrame frame;
}

final class SimulationVehicleEvent extends SimulationScenarioEvent {
  SimulationVehicleEvent({
    required super.atMs,
    required this.key,
    required Object? value,
  }) : value = const StructuredValueCodec().normalize(
         value,
         pluginId: 'argo.simulation',
       ) {
    VehicleDataBus.validateKey(key);
  }

  final String key;
  final StructuredValue value;
}

/// A validated, time-ordered simulation scenario independent from Flutter.
final class SimulationScenario {
  SimulationScenario({
    required this.loop,
    required Iterable<SimulationScenarioEvent> events,
  }) : events = List.unmodifiable(_orderEvents(events));

  final bool loop;
  final List<SimulationScenarioEvent> events;

  static SimulationScenario fromJsonString(String source) {
    return fromJson(jsonDecode(source));
  }

  static SimulationScenario fromJson(Object? source) {
    if (source is! Map<String, Object?>) {
      throw const FormatException('Scenario root must be a JSON object.');
    }
    final schemaVersion = source['schemaVersion'];
    if (schemaVersion != simulationScenarioSchemaVersion) {
      throw FormatException(
        'Unsupported simulation scenario schema version: $schemaVersion.',
      );
    }
    final loop = source['loop'] ?? false;
    if (loop is! bool) {
      throw const FormatException('Scenario "loop" must be a boolean.');
    }
    final rawEvents = source['events'];
    if (rawEvents is! List<Object?>) {
      throw const FormatException('Scenario "events" must be a JSON array.');
    }

    final events = <SimulationScenarioEvent>[];
    for (var index = 0; index < rawEvents.length; index++) {
      try {
        events.add(_parseEvent(rawEvents[index]));
      } on Object catch (error) {
        throw FormatException('Invalid scenario event at index $index: $error');
      }
    }
    return SimulationScenario(loop: loop, events: events);
  }

  static Future<SimulationScenario> load(File file) async {
    try {
      return fromJsonString(await file.readAsString());
    } on Object catch (error) {
      throw FormatException(
        'Could not load simulation scenario "${file.path}": $error',
      );
    }
  }

  static SimulationScenarioEvent _parseEvent(Object? source) {
    if (source is! Map<String, Object?>) {
      throw const FormatException('Event must be a JSON object.');
    }
    final atMs = _requiredInt(source, 'atMs');
    if (atMs < 0) {
      throw const FormatException('"atMs" must not be negative.');
    }
    final type = source['type'];
    return switch (type) {
      'can' => _parseCanEvent(source, atMs),
      'vehicle' => _parseVehicleEvent(source, atMs),
      _ => throw FormatException('Unsupported event type: $type.'),
    };
  }

  static SimulationCanEvent _parseCanEvent(
    Map<String, Object?> source,
    int atMs,
  ) {
    final bus = _requiredString(source, 'bus');
    final id = _requiredInt(source, 'id');
    final extended = source['extended'] ?? false;
    if (extended is! bool) {
      throw const FormatException('"extended" must be a boolean.');
    }
    final rawData = source['data'];
    if (rawData is! List<Object?>) {
      throw const FormatException('CAN event "data" must be an array.');
    }
    final data = <int>[];
    for (var index = 0; index < rawData.length; index++) {
      final byte = rawData[index];
      if (byte is! int) {
        throw FormatException('CAN data byte $index must be an integer.');
      }
      data.add(byte);
    }
    return SimulationCanEvent(
      atMs: atMs,
      frame: CanFrame(bus: bus, id: id, data: data, extended: extended),
    );
  }

  static SimulationVehicleEvent _parseVehicleEvent(
    Map<String, Object?> source,
    int atMs,
  ) {
    if (!source.containsKey('value')) {
      throw const FormatException('Vehicle event requires "value".');
    }
    return SimulationVehicleEvent(
      atMs: atMs,
      key: _requiredString(source, 'key'),
      value: source['value'],
    );
  }

  static int _requiredInt(Map<String, Object?> source, String name) {
    final value = source[name];
    if (value is! int) {
      throw FormatException('"$name" must be an integer.');
    }
    return value;
  }

  static String _requiredString(Map<String, Object?> source, String name) {
    final value = source[name];
    if (value is! String || value.isEmpty) {
      throw FormatException('"$name" must be a non-empty string.');
    }
    return value;
  }

  static List<SimulationScenarioEvent> _orderEvents(
    Iterable<SimulationScenarioEvent> source,
  ) {
    final indexed = <({SimulationScenarioEvent event, int index})>[];
    var index = 0;
    for (final event in source) {
      indexed.add((event: event, index: index++));
    }
    indexed.sort((left, right) {
      final timestampOrder = left.event.atMs.compareTo(right.event.atMs);
      return timestampOrder != 0
          ? timestampOrder
          : left.index.compareTo(right.index);
    });
    return [for (final item in indexed) item.event];
  }
}
