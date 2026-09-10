import 'dart:async';

import 'package:argo/core/audio/audio_service.dart';
import 'package:argo/core/audio/audio_types.dart';
import 'package:argo/core/audio/in_memory_audio_backend.dart';
import 'package:argo/core/connectivity/connectivity_service.dart';
import 'package:argo/core/diagnostics/diagnostics_service.dart';
import 'package:argo/core/settings/app_setting_keys.dart';
import 'package:argo/core/settings/settings_service.dart';
import 'package:argo/core/settings/settings_store.dart';
import 'package:argo/integrations/bluetooth/bluetooth_call_audio.dart';
import 'package:flutter_test/flutter_test.dart';

class Store implements SettingsStore {
  @override
  Future<SettingsDocument> read() async => SettingsDocument();
  @override
  Future<void> write(SettingsDocument value) async {}
}

class Connection implements ConnectivityService {
  final updates = StreamController<ConnectivitySnapshot>.broadcast(sync: true);
  @override
  ConnectivitySnapshot get connectivity =>
      const ConnectivitySnapshot(available: true);
  @override
  Stream<ConnectivitySnapshot> get connectivityChanges => updates.stream;
  @override
  Future<void> connectivityCommand(
    String action, {
    String target = '',
    bool accept = false,
    int prompt = 0,
  }) async {}
}

void main() {
  test(
    'incoming/active calls hold focus, release on loss, and never select media',
    () async {
      final settings = await SettingsService.load(
        schema: AppSettingKeys.createSchema(),
        store: Store(),
      );
      final audio = await DefaultAudioService.start(
        backend: InMemoryAudioBackend(),
        settings: settings,
        diagnostics: DiagnosticsService(),
      );
      await audio.registerSource(
        AudioSource(id: 'player.media', role: AudioSourceRole.media),
      );
      await audio.setSourceActive('player.media', true);
      await audio.selectNextSource();
      final connection = Connection();
      final calls = BluetoothCallAudio(connection, audio);
      for (final state in ['incoming', 'active']) {
        connection.updates.add(
          ConnectivitySnapshot(
            available: true,
            calls: {
              'calls': [
                {'state': state},
              ],
            },
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(audio.current.effectiveSourceGains['player.media'], 0.15);
        expect(audio.current.selectedSource, 'player.media');
      }
      connection.updates.add(const ConnectivitySnapshot(available: false));
      await Future<void>.delayed(Duration.zero);
      expect(audio.current.effectiveSourceGains['player.media'], 1);
      expect(audio.current.focusSources, isEmpty);
      await calls.close();
      await connection.updates.close();
      await audio.close();
      await settings.close();
    },
  );
}
