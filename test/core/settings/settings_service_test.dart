import 'dart:convert';
import 'dart:io';

import 'package:argo/core/settings/json_file_settings_store.dart';
import 'package:argo/core/settings/setting_key.dart';
import 'package:argo/core/settings/settings_schema.dart';
import 'package:argo/core/settings/settings_service.dart';
import 'package:argo/core/settings/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

final _counterKey = SettingKey<int>(
  id: 'test.counter.value',
  defaultValue: 7,
  serialize: (value) => value,
  deserialize: (value) {
    if (value is! int) throw const FormatException('Expected an integer.');
    return value;
  },
);

void main() {
  late Directory temporaryDirectory;
  late File settingsFile;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'argo_settings_test_',
    );
    settingsFile = File('${temporaryDirectory.path}/settings.json');
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('returns a typed default when no value is stored', () async {
    final service = await _loadFromFile(settingsFile);

    expect(service.get(_counterKey), 7);

    await service.close();
  });

  test('sets and retrieves a typed value', () async {
    final service = await _loadFromFile(settingsFile);

    await service.set(_counterKey, 42);

    expect(service.get(_counterKey), 42);
    await service.close();
  });

  test('persists values across service recreation', () async {
    final first = await _loadFromFile(settingsFile);
    await first.set(_counterKey, 81);
    await first.close();

    final second = await _loadFromFile(settingsFile);

    expect(second.get(_counterKey), 81);
    await second.close();
  });

  test('reset removes the stored value and restores the default', () async {
    final first = await _loadFromFile(settingsFile);
    await first.set(_counterKey, 12);
    await first.reset(_counterKey);

    expect(first.get(_counterKey), 7);
    await first.close();

    final second = await _loadFromFile(settingsFile);
    expect(second.get(_counterKey), 7);
    final document = jsonDecode(await settingsFile.readAsString()) as Map;
    expect(document['values'], isNot(contains(_counterKey.id)));
    await second.close();
  });

  test('falls back when a stored value is malformed', () async {
    await _writeDocument(settingsFile, values: {_counterKey.id: 'invalid'});
    final diagnostics = <SettingsDiagnostic>[];

    final service = await _loadFromFile(
      settingsFile,
      onDiagnostic: diagnostics.add,
    );

    expect(service.get(_counterKey), 7);
    expect(
      diagnostics.map((diagnostic) => diagnostic.message),
      contains(contains(_counterKey.id)),
    );
    await service.close();
  });

  test('preserves a corrupt document and starts with defaults', () async {
    await settingsFile.parent.create(recursive: true);
    await settingsFile.writeAsString('{this is not JSON');
    final diagnostics = <SettingsDiagnostic>[];

    final service = await _loadFromFile(
      settingsFile,
      onDiagnostic: diagnostics.add,
    );

    expect(service.get(_counterKey), 7);
    expect(await settingsFile.exists(), isFalse);
    final preservedFiles = await temporaryDirectory
        .list()
        .where((entry) => entry.path.contains('settings.json.corrupt.'))
        .toList();
    expect(preservedFiles, hasLength(1));
    expect(
      diagnostics.map((diagnostic) => diagnostic.message),
      contains(contains('starting with defaults')),
    );
    await service.close();
  });

  test('preserves unknown keys and root fields while writing', () async {
    await _writeDocument(
      settingsFile,
      values: {
        _counterKey.id: 9,
        'future.feature.setting': {'enabled': true},
      },
      additionalRootValues: {
        'futureMetadata': {'revision': 2},
      },
    );
    final service = await _loadFromFile(settingsFile);

    await service.set(_counterKey, 10);
    await service.close();

    final document =
        jsonDecode(await settingsFile.readAsString()) as Map<String, dynamic>;
    expect(
      document['values']['future.feature.setting'],
      equals({'enabled': true}),
    );
    expect(document['futureMetadata'], equals({'revision': 2}));
  });

  test('serializes concurrent writes', () async {
    final store = _ConcurrencyCheckingStore();
    final service = await SettingsService.load(schema: _schema(), store: store);

    await Future.wait([
      for (var value = 0; value < 20; value++) service.set(_counterKey, value),
    ]);

    expect(store.maximumConcurrentWrites, 1);
    expect(service.get(_counterKey), 19);
    expect(store.document.values[_counterKey.id], 19);
    await service.close();
  });

  test('rejects duplicate and conflicting key definitions', () async {
    final schema = _schema();
    final conflictingKey = SettingKey<int>(
      id: _counterKey.id,
      defaultValue: 0,
      serialize: (value) => value,
      deserialize: (value) => value as int,
    );

    expect(() => schema.register(conflictingKey), throwsStateError);

    final service = await SettingsService.load(
      schema: schema,
      store: _ConcurrencyCheckingStore(),
    );
    expect(() => service.get(conflictingKey), throwsStateError);
    await service.close();
  });

  test('ARGO_SETTINGS_FILE overrides the platform default', () {
    final resolved = ArgoSettingsFile.fromEnvironment({
      'ARGO_SETTINGS_FILE': settingsFile.path,
    });

    expect(resolved.path, settingsFile.absolute.path);
  });
}

SettingsSchema _schema() => SettingsSchema()..register(_counterKey);

Future<SettingsService> _loadFromFile(
  File file, {
  SettingsDiagnosticHandler? onDiagnostic,
}) => SettingsService.load(
  schema: _schema(),
  store: JsonFileSettingsStore(file: file, onDiagnostic: onDiagnostic),
  onDiagnostic: onDiagnostic,
);

Future<void> _writeDocument(
  File file, {
  required Map<String, Object?> values,
  Map<String, Object?> additionalRootValues = const {},
}) async {
  await file.parent.create(recursive: true);
  await file.writeAsString(
    jsonEncode({
      ...additionalRootValues,
      'schemaVersion': currentSettingsSchemaVersion,
      'values': values,
    }),
  );
}

final class _ConcurrencyCheckingStore implements SettingsStore {
  SettingsDocument document = SettingsDocument();
  var _concurrentWrites = 0;
  var maximumConcurrentWrites = 0;

  @override
  Future<SettingsDocument> read() async => document;

  @override
  Future<void> write(SettingsDocument nextDocument) async {
    _concurrentWrites++;
    if (_concurrentWrites > maximumConcurrentWrites) {
      maximumConcurrentWrites = _concurrentWrites;
    }
    try {
      await Future<void>.delayed(const Duration(milliseconds: 2));
      document = nextDocument;
    } finally {
      _concurrentWrites--;
    }
  }
}
