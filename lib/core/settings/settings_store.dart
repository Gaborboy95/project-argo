/// Current on-disk settings document schema.
const currentSettingsSchemaVersion = 1;

final class SettingsDocument {
  SettingsDocument({
    this.schemaVersion = currentSettingsSchemaVersion,
    Map<String, Object?> values = const {},
    Map<String, Object?> additionalRootValues = const {},
  }) : values = Map.unmodifiable(values),
       additionalRootValues = Map.unmodifiable(additionalRootValues);

  final int schemaVersion;
  final Map<String, Object?> values;

  /// Unrecognized root fields retained for forward compatibility.
  final Map<String, Object?> additionalRootValues;

  SettingsDocument withValues(Map<String, Object?> nextValues) =>
      SettingsDocument(
        schemaVersion: schemaVersion,
        values: nextValues,
        additionalRootValues: additionalRootValues,
      );
}

abstract interface class SettingsStore {
  Future<SettingsDocument> read();

  Future<void> write(SettingsDocument document);
}

final class SettingsDiagnostic {
  const SettingsDiagnostic(this.message, {this.error, this.stackTrace});

  final String message;
  final Object? error;
  final StackTrace? stackTrace;
}

typedef SettingsDiagnosticHandler = void Function(
  SettingsDiagnostic diagnostic,
);
