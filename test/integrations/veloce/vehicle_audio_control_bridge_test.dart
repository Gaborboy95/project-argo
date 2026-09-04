import 'dart:io';

import 'package:argo/core/audio/audio_service.dart';
import 'package:argo/core/audio/in_memory_audio_backend.dart';
import 'package:argo/core/audio/audio_types.dart';
import 'package:argo/core/diagnostics/diagnostics_service.dart';
import 'package:argo/core/settings/app_setting_keys.dart';
import 'package:argo/core/settings/settings_service.dart';
import 'package:argo/core/settings/settings_store.dart';
import 'package:argo/integrations/veloce/vehicle_audio_control_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veloce_lua_core/veloce_lua_core.dart';

void main() {
  late _Fixture fixture;

  setUp(() async => fixture = await _Fixture.create());
  tearDown(() => fixture.close());

  test('rejects anonymous audio commands', () async {
    await fixture.publish();
    expect(fixture.audio.current.masterVolume, 0.5);
    expect(fixture.diagnostics.latest?.message, contains('anonymous'));
  });

  test('rejects unrelated plugins', () async {
    await fixture.publish(sourcePluginId: 'unrelated.plugin');
    expect(fixture.audio.current.masterVolume, 0.5);
    expect(fixture.diagnostics.latest?.message, contains('unauthorized'));
  });

  test('accepts running plugin inside selected integration', () async {
    fixture.registerAuthorized();
    await fixture.publish(sourcePluginId: fixture.pluginId);
    expect(fixture.audio.current.masterVolume, 0.55);
  });

  test('mute and source commands have fixed safe effects', () async {
    fixture.registerAuthorized();
    await fixture.audio.registerSource(
      AudioSource(id: 'source.one', role: AudioSourceRole.media),
    );
    await fixture.audio.registerSource(
      AudioSource(id: 'source.two', role: AudioSourceRole.media),
    );

    await fixture.publish(
      topic: VehicleAudioControlBridge.muteToggleTopic,
      sourcePluginId: fixture.pluginId,
    );
    await fixture.publish(
      topic: VehicleAudioControlBridge.sourceNextTopic,
      sourcePluginId: fixture.pluginId,
    );
    expect(fixture.audio.current.muted, isTrue);
    expect(fixture.audio.current.selectedSource, 'source.one');
  });

  test('close removes every Veloce event subscription', () async {
    expect(
      fixture.bus.subscriptionCountFor('argo.vehicle-audio-control-bridge'),
      5,
    );
    await fixture.bridge.close();
    expect(
      fixture.bus.subscriptionCountFor('argo.vehicle-audio-control-bridge'),
      0,
    );
  });
}

final class _Fixture {
  _Fixture._({
    required this.root,
    required this.pluginDirectory,
    required this.bus,
    required this.registry,
    required this.diagnostics,
    required this.settings,
    required this.audio,
    required this.bridge,
  });

  final Directory root;
  final Directory pluginDirectory;
  final PluginEventBus bus;
  final PluginRegistry registry;
  final DiagnosticsService diagnostics;
  final SettingsService settings;
  final DefaultAudioService audio;
  final VehicleAudioControlBridge bridge;
  final loaded = <String>{};
  String get pluginId => 'example.audio-policy';

  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp('argo-audio-bridge-');
    final pluginDirectory = Directory.fromUri(
      root.uri.resolve('plugins/audio/'),
    );
    await pluginDirectory.create(recursive: true);
    final bus = PluginEventBus();
    final registry = PluginRegistry();
    final diagnostics = DiagnosticsService();
    final settings = await SettingsService.load(
      schema: AppSettingKeys.createSchema(),
      store: _MemoryStore(),
    );
    final audio = await DefaultAudioService.start(
      backend: InMemoryAudioBackend(),
      settings: settings,
      diagnostics: diagnostics,
    );
    late _Fixture fixture;
    final bridge = await VehicleAudioControlBridge.start(
      eventBus: bus,
      pluginRegistry: registry,
      isPluginLoaded: (id) => fixture.loaded.contains(id),
      activeIntegrationPluginRoot: Directory.fromUri(
        root.uri.resolve('plugins/'),
      ),
      audio: audio,
      diagnostics: diagnostics,
    );
    fixture = _Fixture._(
      root: root,
      pluginDirectory: pluginDirectory,
      bus: bus,
      registry: registry,
      diagnostics: diagnostics,
      settings: settings,
      audio: audio,
      bridge: bridge,
    );
    return fixture;
  }

  void registerAuthorized() {
    registry.put(
      PluginRecord(
        directoryPath: pluginDirectory.path,
        manifest: PluginManifest(
          id: pluginId,
          name: pluginId,
          version: const SemanticVersion(major: 1, minor: 0, patch: 0),
          apiVersion: '1',
          entrypoint: 'main.lua',
          permissions: const [],
        ),
        state: PluginState.running,
        enabled: true,
      ),
    );
    loaded.add(pluginId);
  }

  Future<void> publish({
    String topic = VehicleAudioControlBridge.volumeUpTopic,
    String? sourcePluginId,
  }) async {
    bus.publish(topic, const {}, sourcePluginId: sourcePluginId);
    await bus.flush();
  }

  Future<void> close() async {
    await bridge.close();
    await audio.close();
    await settings.close();
    await bus.close();
    await registry.close();
    await root.delete(recursive: true);
  }
}

final class _MemoryStore implements SettingsStore {
  var document = SettingsDocument();
  @override
  Future<SettingsDocument> read() async => document;
  @override
  Future<void> write(SettingsDocument document) async =>
      this.document = document;
}
