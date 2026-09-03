import 'dart:async';

import 'setting_key.dart';
import 'settings_schema.dart';
import 'settings_store.dart';

final class SettingChange {
  const SettingChange({
    required this.keyId,
    required this.previousValue,
    required this.value,
  });

  final String keyId;
  final Object? previousValue;
  final Object? value;
}

/// Typed in-memory settings with serialized persistent mutations.
final class SettingsService {
  SettingsService._({
    required this._schema,
    required this._store,
    required this._document,
    required this._values,
    required this._rawValues,
    required this._onDiagnostic,
  });

  static Future<SettingsService> load({
    required SettingsSchema schema,
    required SettingsStore store,
    SettingsDiagnosticHandler? onDiagnostic,
  }) async {
    final document = await store.read();
    final rawValues = Map<String, Object?>.of(document.values);
    final values = <String, Object?>{};

    for (final key in schema.keys) {
      if (!rawValues.containsKey(key.id)) {
        values[key.id] = key.defaultValue;
        continue;
      }
      try {
        values[key.id] = key.deserialize(rawValues[key.id]);
      } on Object catch (error, stackTrace) {
        values[key.id] = key.defaultValue;
        rawValues.remove(key.id);
        _report(
          onDiagnostic,
          SettingsDiagnostic(
            'Stored value for "${key.id}" is invalid; using its default.',
            error: error,
            stackTrace: stackTrace,
          ),
        );
      }
    }

    return SettingsService._(
      schema: schema,
      store: store,
      document: document.withValues(rawValues),
      values: values,
      rawValues: rawValues,
      onDiagnostic: onDiagnostic,
    );
  }

  final SettingsSchema _schema;
  final SettingsStore _store;
  SettingsDocument _document;
  Map<String, Object?> _values;
  Map<String, Object?> _rawValues;
  final SettingsDiagnosticHandler? _onDiagnostic;
  final StreamController<SettingChange> _changes =
      StreamController<SettingChange>.broadcast(sync: true);
  Future<void> _operationTail = Future<void>.value();
  var _closed = false;

  Stream<SettingChange> get changes => _changes.stream;
  Map<String, Object?> get snapshot => Map.unmodifiable(_values);

  T get<T>(SettingKey<T> key) {
    _schema.requireRegistered(key);
    return _values[key.id] as T;
  }

  Stream<T> watch<T>(SettingKey<T> key) async* {
    yield get(key);
    yield* changes
        .where((change) => change.keyId == key.id)
        .map((change) => change.value as T);
  }

  Future<void> set<T>(SettingKey<T> key, T value) {
    _ensureOpen();
    _schema.requireRegistered(key);
    final serialized = key.serialize(value);
    _validateJsonValue(serialized, keyId: key.id);
    final normalized = key.deserialize(serialized);

    return _serializeWrite(() async {
      final previous = get(key);
      final nextRawValues = Map<String, Object?>.of(_rawValues)
        ..[key.id] = serialized;
      final nextDocument = _document.withValues(nextRawValues);
      await _store.write(nextDocument);
      _document = nextDocument;
      _rawValues = nextRawValues;
      _values = Map<String, Object?>.of(_values)..[key.id] = normalized;
      if (previous != normalized) {
        _changes.add(
          SettingChange(
            keyId: key.id,
            previousValue: previous,
            value: normalized,
          ),
        );
      }
    });
  }

  Future<void> reset<T>(SettingKey<T> key) {
    _ensureOpen();
    _schema.requireRegistered(key);

    return _serializeWrite(() async {
      final previous = get(key);
      if (!_rawValues.containsKey(key.id) && previous == key.defaultValue) {
        return;
      }
      final nextRawValues = Map<String, Object?>.of(_rawValues)..remove(key.id);
      final nextDocument = _document.withValues(nextRawValues);
      await _store.write(nextDocument);
      _document = nextDocument;
      _rawValues = nextRawValues;
      _values = Map<String, Object?>.of(_values)..[key.id] = key.defaultValue;
      if (previous != key.defaultValue) {
        _changes.add(
          SettingChange(
            keyId: key.id,
            previousValue: previous,
            value: key.defaultValue,
          ),
        );
      }
    });
  }

  Future<void> flush() => _operationTail;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await flush();
    await _changes.close();
  }

  Future<void> _serializeWrite(Future<void> Function() operation) {
    final completer = Completer<void>();
    _operationTail = _operationTail.then((_) async {
      try {
        await operation();
        completer.complete();
      } on Object catch (error, stackTrace) {
        _report(
          _onDiagnostic,
          SettingsDiagnostic(
            'Could not persist application settings.',
            error: error,
            stackTrace: stackTrace,
          ),
        );
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  void _ensureOpen() {
    if (_closed) throw StateError('Settings service is closed.');
  }

  static void _validateJsonValue(Object? value, {required String keyId}) {
    bool valid(Object? item) => switch (item) {
      null || bool() || String() => true,
      num() => item.isFinite,
      List<Object?>() => item.every(valid),
      Map<String, Object?>() => item.values.every(valid),
      _ => false,
    };

    if (!valid(value)) {
      throw ArgumentError.value(
        value,
        keyId,
        'Setting serializer returned a non-JSON value',
      );
    }
  }

  static void _report(
    SettingsDiagnosticHandler? handler,
    SettingsDiagnostic diagnostic,
  ) {
    try {
      handler?.call(diagnostic);
    } on Object {
      // Diagnostics must not break settings behavior.
    }
  }
}
