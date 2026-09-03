import 'dart:convert';
import 'dart:io';

import 'settings_store.dart';

/// Resolves the application-owned settings file without a Flutter dependency.
abstract final class ArgoSettingsFile {
  static File fromEnvironment(Map<String, String> environment) {
    final override = environment['ARGO_SETTINGS_FILE']?.trim();
    if (override != null && override.isNotEmpty) {
      return File(override).absolute;
    }

    final String? configurationRoot;
    if (Platform.isWindows) {
      configurationRoot =
          _value(environment, 'APPDATA') ?? _value(environment, 'LOCALAPPDATA');
    } else if (Platform.isMacOS) {
      final home = _value(environment, 'HOME');
      configurationRoot = home == null
          ? null
          : Directory.fromUri(
              Directory(home).absolute.uri
                  .resolve('Library/Application Support/'),
            ).path;
    } else {
      final xdgRoot = _value(environment, 'XDG_CONFIG_HOME');
      final home = _value(environment, 'HOME');
      configurationRoot =
          xdgRoot ??
          (home == null
              ? null
              : Directory.fromUri(
                  Directory(home).absolute.uri.resolve('.config/'),
                ).path);
    }

    if (configurationRoot == null) {
      throw StateError(
        'Could not resolve a per-user configuration directory for Argo.',
      );
    }
    return File.fromUri(
      Directory(configurationRoot).absolute.uri
          .resolve('project-argo/settings.json'),
    );
  }

  static String? _value(Map<String, String> environment, String name) {
    final value = environment[name]?.trim();
    return value == null || value.isEmpty ? null : value;
  }
}

/// JSON settings persistence with same-directory, flushed replacement writes.
final class JsonFileSettingsStore implements SettingsStore {
  JsonFileSettingsStore({required this.file, this.onDiagnostic});

  final File file;
  final SettingsDiagnosticHandler? onDiagnostic;

  File get _temporaryFile => File('${file.path}.tmp');
  File get _backupFile => File('${file.path}.bak');

  @override
  Future<SettingsDocument> read() async {
    await _recoverInterruptedReplacement();
    if (!await file.exists()) return SettingsDocument();

    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('Settings root must be a JSON object.');
      }
      final schemaVersion = decoded['schemaVersion'];
      if (schemaVersion != currentSettingsSchemaVersion) {
        throw FormatException(
          'Unsupported settings schema version: $schemaVersion.',
        );
      }
      final rawValues = decoded['values'];
      if (rawValues is! Map<String, Object?>) {
        throw const FormatException('Settings values must be a JSON object.');
      }
      final additionalRootValues = Map<String, Object?>.of(decoded)
        ..remove('schemaVersion')
        ..remove('values');
      return SettingsDocument(
        schemaVersion: schemaVersion as int,
        values: rawValues,
        additionalRootValues: additionalRootValues,
      );
    } on Object catch (error, stackTrace) {
      final preservedPath = await _preserveCorruptFile();
      _report(
        SettingsDiagnostic(
          preservedPath == null
              ? 'Settings are corrupt; starting with defaults.'
              : 'Settings are corrupt; preserved at $preservedPath and '
                    'starting with defaults.',
          error: error,
          stackTrace: stackTrace,
        ),
      );
      return SettingsDocument();
    }
  }

  @override
  Future<void> write(SettingsDocument document) async {
    if (document.schemaVersion != currentSettingsSchemaVersion) {
      throw ArgumentError.value(
        document.schemaVersion,
        'document.schemaVersion',
        'Unsupported settings schema version',
      );
    }
    final encoded = jsonEncode({
      ...document.additionalRootValues,
      'schemaVersion': document.schemaVersion,
      'values': document.values,
    });

    await file.parent.create(recursive: true);
    final temporary = _temporaryFile;
    final backup = _backupFile;
    if (await temporary.exists()) await temporary.delete();
    await temporary.writeAsString(encoded, flush: true);

    var movedOriginal = false;
    if (await file.exists()) {
      if (await backup.exists()) await backup.delete();
      await file.rename(backup.path);
      movedOriginal = true;
    }
    try {
      await temporary.rename(file.path);
    } on Object {
      if (await temporary.exists()) await temporary.delete();
      if (movedOriginal && await backup.exists() && !await file.exists()) {
        await backup.rename(file.path);
      }
      rethrow;
    }

    if (await backup.exists()) {
      try {
        await backup.delete();
      } on Object catch (error, stackTrace) {
        _report(
          SettingsDiagnostic(
            'Could not remove the previous settings backup.',
            error: error,
            stackTrace: stackTrace,
          ),
        );
      }
    }
  }

  Future<void> _recoverInterruptedReplacement() async {
    final backup = _backupFile;
    if (await file.exists() || !await backup.exists()) return;
    try {
      await file.parent.create(recursive: true);
      await backup.rename(file.path);
      _report(
        const SettingsDiagnostic(
          'Recovered settings from an interrupted replacement.',
        ),
      );
    } on Object catch (error, stackTrace) {
      _report(
        SettingsDiagnostic(
          'Could not recover the previous settings backup.',
          error: error,
          stackTrace: stackTrace,
        ),
      );
    }
  }

  Future<String?> _preserveCorruptFile() async {
    if (!await file.exists()) return null;
    final suffix = DateTime.now().toUtc().microsecondsSinceEpoch;
    final corruptFile = File('${file.path}.corrupt.$suffix');
    try {
      await file.rename(corruptFile.path);
      return corruptFile.path;
    } on Object catch (error, stackTrace) {
      _report(
        SettingsDiagnostic(
          'Could not preserve the corrupt settings file.',
          error: error,
          stackTrace: stackTrace,
        ),
      );
      return null;
    }
  }

  void _report(SettingsDiagnostic diagnostic) {
    try {
      final handler = onDiagnostic;
      if (handler != null) {
        handler(diagnostic);
      } else {
        stderr.writeln('[Argo settings] ${diagnostic.message}');
        if (diagnostic.error != null) {
          stderr.writeln('[Argo settings] ${diagnostic.error}');
        }
      }
    } on Object {
      // Diagnostics must not prevent settings recovery or persistence.
    }
  }
}
