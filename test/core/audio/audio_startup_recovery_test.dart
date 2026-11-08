import 'dart:async';

import 'package:argo/core/audio/audio_backend.dart';
import 'package:argo/core/audio/audio_service.dart';
import 'package:argo/core/audio/audio_types.dart';
import 'package:argo/core/diagnostics/diagnostics_service.dart';
import 'package:argo/core/diagnostics/service_failure.dart';
import 'package:argo/core/settings/app_setting_keys.dart';
import 'package:argo/core/settings/settings_service.dart';
import 'package:argo/core/settings/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'generic restore resolves saved output before any level or mute write',
    () async {
      final settings = await SettingsService.load(
        schema: AppSettingKeys.createSchema(),
        store: _Store(),
      );
      await settings.set(AppSettingKeys.audioPreferredOutput, 'missing');
      await settings.set(AppSettingKeys.audioMasterVolume, .9);
      final backend = _Backend();
      final audio = await DefaultAudioService.start(
        backend: backend,
        settings: settings,
        diagnostics: DiagnosticsService(),
      );
      expect(backend.operations, ['start', 'select:missing']);
      expect(audio.current.backendAvailable, isFalse);
      backend.emit();
      expect(audio.current.backendAvailable, isFalse);
      expect(audio.current.selectedOutput, 'missing');
      await audio.setMasterVolume(.8);
      await audio.setMuted(true);
      expect(backend.operations, ['start', 'select:missing']);
      await audio.close();
      expect(backend.operations.last, 'close');
      await settings.close();
    },
  );

  test(
    'unavailable audio service renders unavailable state and retries startup',
    () async {
      final settings = await SettingsService.load(
        schema: AppSettingKeys.createSchema(),
        store: _Store(),
      );
      final backend = _Backend()..failStart = true;
      final audio = await DefaultAudioService.start(
        backend: backend,
        settings: settings,
        diagnostics: DiagnosticsService(),
      );
      expect(audio.current.failure?.kind, FailureKind.missingService);
      expect(audio.current.backendAvailable, isFalse);
      expect(backend.operations, ['start']);
      backend.failStart = false;
      await audio.selectOutput('desktop');
      expect(audio.current.failure, isNull);
      expect(audio.current.backendAvailable, isTrue);
      expect(backend.operations, ['start', 'start', 'select:desktop']);
      await audio.close();
      await settings.close();
    },
  );
}

class _Backend extends Fake implements AudioBackend {
  final operations = <String>[];
  final _changes = StreamController<AudioBackendState>.broadcast(sync: true);
  bool failStart = false;
  String? selected = 'desktop';
  @override
  AudioBackendState get current => AudioBackendState(
    available: !failStart,
    capabilities: const AudioBackendCapabilities(
      masterVolume: true,
      mute: true,
      outputSelection: true,
    ),
    masterVolume: .25,
    muted: false,
    selectedOutput: selected,
  );
  @override
  Stream<AudioBackendState> get changes => _changes.stream;
  void emit() => _changes.add(current);
  @override
  Future<void> start() async {
    operations.add('start');
    if (failStart) throw StateError('Audio server unavailable');
  }

  @override
  Future<void> selectOutput(String? outputId) async {
    operations.add('select:$outputId');
    if (outputId == 'missing') throw StateError('Missing output');
    selected = outputId;
    emit();
  }

  @override
  Future<void> setMasterVolume(double value) async =>
      operations.add('volume:$value');
  @override
  Future<void> setMuted(bool value) async => operations.add('mute:$value');
  @override
  Future<void> close() async {
    operations.add('close');
    await _changes.close();
  }
}

class _Store implements SettingsStore {
  SettingsDocument document = SettingsDocument();
  @override
  Future<SettingsDocument> read() async => document;
  @override
  Future<void> write(SettingsDocument document) async =>
      this.document = document;
}
