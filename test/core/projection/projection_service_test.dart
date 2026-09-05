import 'package:argo/core/audio/audio_service.dart';
import 'package:argo/core/audio/audio_types.dart';
import 'package:argo/core/audio/in_memory_audio_backend.dart';
import 'package:argo/core/diagnostics/diagnostics_service.dart';
import 'package:argo/core/projection/in_memory_projection_backend.dart';
import 'package:argo/core/projection/projection_models.dart';
import 'package:argo/core/projection/projection_service.dart';
import 'package:argo/core/projection/projection_types.dart';
import 'package:argo/core/settings/app_setting_keys.dart';
import 'package:argo/core/settings/settings_service.dart';
import 'package:argo/core/settings/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('projection audio roles map to generic Argo audio roles', () {
    expect(
      audioRoleForProjection(ProjectionAudioRole.media),
      AudioSourceRole.media,
    );
    expect(
      audioRoleForProjection(ProjectionAudioRole.speech),
      AudioSourceRole.navigation,
    );
    expect(
      audioRoleForProjection(ProjectionAudioRole.communication),
      AudioSourceRole.communication,
    );
    expect(
      audioRoleForProjection(ProjectionAudioRole.system),
      AudioSourceRole.system,
    );
  });

  test(
    'navigation projection focus ducks media without changing master',
    () async {
      final fixture = await _Fixture.start();
      await fixture.audio.registerSource(
        AudioSource(id: 'player.media', role: AudioSourceRole.media),
      );
      await fixture.audio.setSourceActive('player.media', true);
      final master = fixture.audio.current.masterVolume;

      fixture.backend.emit(_snapshot(audioRole: ProjectionAudioRole.speech));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(fixture.audio.current.masterVolume, master);
      expect(
        fixture.audioBackend.sourceGains['player.media'],
        closeTo(0.35, 0.0001),
      );
      expect(fixture.backend.audioGains['session/speech'], 1);
      // A higher-priority non-projection source also updates native projection
      // gain through the same policy; releasing it restores the prior gain.
      await fixture.audio.registerSource(
        AudioSource(id: 'call', role: AudioSourceRole.communication),
      );
      await fixture.audio.setSourceActive('call', true);
      final focus = await fixture.audio.requestFocus('call', duckingGain: 0.2);
      await Future<void>.delayed(Duration.zero);
      expect(
        fixture.backend.audioGains['session/speech'],
        closeTo(0.2, 0.0001),
      );
      await focus.release();
      await Future<void>.delayed(Duration.zero);
      expect(fixture.backend.audioGains['session/speech'], 1);
      await fixture.close();
    },
  );

  test('duplicate semantic backend snapshots are suppressed', () async {
    final fixture = await _Fixture.start();
    var count = 0;
    final subscription = fixture.projection.changes.listen((_) => count++);
    final snapshot = _snapshot(audioRole: ProjectionAudioRole.media);

    fixture.backend.emit(snapshot);
    await Future<void>.delayed(Duration.zero);
    fixture.backend.emit(snapshot);
    await Future<void>.delayed(Duration.zero);

    expect(count, 1);
    await subscription.cancel();
    await fixture.close();
  });
}

ProjectionSnapshot _snapshot({required ProjectionAudioRole audioRole}) {
  const device = ProjectionDevice(
    id: 'phone',
    displayName: 'Phone',
    protocol: ProjectionProtocol.androidAuto,
    transport: ProjectionTransport.usb,
  );
  return ProjectionSnapshot(
    backendAvailable: true,
    devices: const [device],
    sessions: [
      ProjectionSession(
        id: 'session',
        device: device,
        state: ProjectionSessionState.streaming,
        audioStreams: [
          ProjectionAudioStream(
            id: 'speech',
            sessionId: 'session',
            role: audioRole,
            active: true,
            hasFocus: true,
          ),
        ],
      ),
    ],
    activeSessionId: 'session',
  );
}

final class _Fixture {
  _Fixture(
    this.settings,
    this.audioBackend,
    this.audio,
    this.backend,
    this.projection,
  );

  static Future<_Fixture> start() async {
    final settings = await SettingsService.load(
      schema: AppSettingKeys.createSchema(),
      store: _MemoryStore(),
    );
    final audioBackend = InMemoryAudioBackend();
    final audio = await DefaultAudioService.start(
      backend: audioBackend,
      settings: settings,
      diagnostics: DiagnosticsService(),
    );
    final backend = InMemoryProjectionBackend();
    final projection = await DefaultProjectionService.start(
      backend: backend,
      audio: audio,
      diagnostics: DiagnosticsService(),
    );
    return _Fixture(settings, audioBackend, audio, backend, projection);
  }

  final SettingsService settings;
  final InMemoryAudioBackend audioBackend;
  final AudioService audio;
  final InMemoryProjectionBackend backend;
  final ProjectionService projection;

  Future<void> close() async {
    await projection.close();
    await audio.close();
    await settings.close();
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
