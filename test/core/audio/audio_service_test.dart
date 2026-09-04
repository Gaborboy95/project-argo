import 'package:argo/core/audio/audio_backend.dart';
import 'package:argo/core/audio/audio_service.dart';
import 'package:argo/core/audio/audio_types.dart';
import 'package:argo/core/audio/in_memory_audio_backend.dart';
import 'package:argo/core/diagnostics/diagnostics_service.dart';
import 'package:argo/core/settings/app_setting_keys.dart';
import 'package:argo/core/settings/settings_service.dart';
import 'package:argo/core/settings/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _MemorySettingsStore store;
  late SettingsService settings;
  late InMemoryAudioBackend backend;
  late DefaultAudioService audio;

  setUp(() async {
    store = _MemorySettingsStore();
    settings = await _settings(store);
    backend = InMemoryAudioBackend();
    audio = await DefaultAudioService.start(
      backend: backend,
      settings: settings,
      diagnostics: DiagnosticsService(),
    );
  });

  tearDown(() async {
    await audio.close();
    await settings.close();
  });

  test(
    'malformed stored audio values fall back through settings validation',
    () async {
      await audio.close();
      await settings.close();
      store.document = SettingsDocument(
        values: {AppSettingKeys.audioMasterVolume.id: 'very loud'},
      );
      settings = await _settings(store);
      backend = InMemoryAudioBackend();
      audio = await DefaultAudioService.start(
        backend: backend,
        settings: settings,
        diagnostics: DiagnosticsService(),
      );
      expect(audio.current.masterVolume, 0.5);
    },
  );

  test('enforces volume bounds and rejects NaN and infinity', () {
    expect(() => audio.setMasterVolume(-0.01), throwsRangeError);
    expect(() => audio.setMasterVolume(1.01), throwsRangeError);
    expect(() => audio.setMasterVolume(double.nan), throwsRangeError);
    expect(() => audio.setMasterVolume(double.infinity), throwsRangeError);
  });

  test('steps volume by its configured bounded increment', () async {
    await audio.setMasterVolume(0.98);
    await audio.volumeStep(AudioVolumeDirection.up);
    expect(audio.current.masterVolume, 1);
    await audio.setMasterVolume(0.02);
    await audio.volumeStep(AudioVolumeDirection.down);
    expect(audio.current.masterVolume, 0);
  });

  test(
    'serializes concurrent steps and suppresses duplicate snapshots',
    () async {
      final changes = <double>[];
      final subscription = audio.changes.listen(
        (state) => changes.add(state.masterVolume),
      );
      addTearDown(subscription.cancel);

      await Future.wait([
        audio.volumeStep(AudioVolumeDirection.up),
        audio.volumeStep(AudioVolumeDirection.up),
      ]);
      expect(audio.current.masterVolume, 0.6);
      final count = changes.length;
      await audio.setMasterVolume(0.6);
      expect(changes, hasLength(count));
    },
  );

  test('mute does not rewrite volume and unmute restores it', () async {
    await audio.setMasterVolume(0.72);
    await audio.setMuted(true);
    await audio.setMuted(false);
    expect(audio.current.masterVolume, 0.72);
    expect(backend.current.masterVolume, 0.72);
  });

  test('stereo supports balance but explicitly rejects fader', () async {
    expect(audio.current.capabilities.balance, isTrue);
    expect(audio.current.capabilities.fader, isFalse);
    await audio.setBalance(0.5);
    expect(backend.channelGains, {
      AudioChannelPosition.left: 0.5,
      AudioChannelPosition.right: 1.0,
    });
    await expectLater(
      audio.setFader(0.5),
      throwsA(isA<UnsupportedAudioFeatureException>()),
    );
  });

  test(
    'four-channel balance and fader combine without gain increase',
    () async {
      await audio.close();
      backend = InMemoryAudioBackend(
        channels: const [
          AudioChannelPosition.frontLeft,
          AudioChannelPosition.frontRight,
          AudioChannelPosition.rearLeft,
          AudioChannelPosition.rearRight,
        ],
      );
      audio = await DefaultAudioService.start(
        backend: backend,
        settings: settings,
        diagnostics: DiagnosticsService(),
      );
      await audio.setBalance(0.5);
      await audio.setFader(0.5);

      expect(audio.current.capabilities.fader, isTrue);
      expect(backend.channelGains, {
        AudioChannelPosition.frontLeft: 0.5,
        AudioChannelPosition.frontRight: 1.0,
        AudioChannelPosition.rearLeft: 0.25,
        AudioChannelPosition.rearRight: 0.5,
      });
      expect(backend.channelGains.values, everyElement(lessThanOrEqualTo(1)));
    },
  );

  test('EQ is bounded to plus or minus 12 dB', () async {
    await audio.setEqualizer(
      const AudioEqualizer(bassDb: -12, midDb: 2, trebleDb: 12),
    );
    expect(backend.equalizer.trebleDb, 12);
    expect(
      () => audio.setEqualizer(const AudioEqualizer(bassDb: 12.01)),
      throwsRangeError,
    );
  });

  test('restores persisted user audio settings', () async {
    await audio.setMasterVolume(0.8);
    await audio.setMuted(true);
    await audio.setBalance(-0.4);
    await audio.setEqualizer(const AudioEqualizer(bassDb: 3));
    await audio.close();
    await settings.close();

    settings = await _settings(store);
    backend = InMemoryAudioBackend();
    audio = await DefaultAudioService.start(
      backend: backend,
      settings: settings,
      diagnostics: DiagnosticsService(),
    );

    expect(audio.current.masterVolume, 0.8);
    expect(audio.current.muted, isTrue);
    expect(audio.current.balance, -0.4);
    expect(audio.current.equalizer.bassDb, 3);
  });

  test('registers sources and composes overlapping duck requests', () async {
    await audio.registerSource(
      AudioSource(id: 'player.media', role: AudioSourceRole.media),
    );
    await audio.registerSource(
      AudioSource(id: 'guidance.navigation', role: AudioSourceRole.navigation),
    );
    await audio.registerSource(
      AudioSource(id: 'phone.call', role: AudioSourceRole.communication),
    );
    for (final id in ['player.media', 'guidance.navigation', 'phone.call']) {
      await audio.setSourceActive(id, true);
    }

    final navigation = await audio.requestFocus('guidance.navigation');
    expect(audio.current.effectiveSourceGains['player.media'], 0.35);
    final call = await audio.requestFocus('phone.call');
    expect(
      audio.current.effectiveSourceGains['player.media'],
      closeTo(0.0525, 0.0001),
    );
    expect(audio.current.effectiveSourceGains['guidance.navigation'], 0.15);

    await navigation.release();
    expect(audio.current.effectiveSourceGains['player.media'], 0.15);
    await call.release();
    expect(audio.current.effectiveSourceGains['player.media'], 1);

    final navigationAgain = await audio.requestFocus('guidance.navigation');
    final callAgain = await audio.requestFocus('phone.call');
    await callAgain.release();
    expect(audio.current.effectiveSourceGains['player.media'], 0.35);
    await navigationAgain.release();
    expect(audio.current.effectiveSourceGains['player.media'], 1);
  });

  test('disabled backend remains host-safe while policy state works', () async {
    await audio.close();
    audio = await DefaultAudioService.start(
      backend: const DisabledAudioBackend(),
      settings: settings,
      diagnostics: DiagnosticsService(),
    );
    await audio.setMasterVolume(0.6);
    await audio.setBalance(0.2);
    expect(audio.current.backendAvailable, isFalse);
    expect(audio.current.masterVolume, 0.6);
  });
}

Future<SettingsService> _settings(SettingsStore store) =>
    SettingsService.load(schema: AppSettingKeys.createSchema(), store: store);

final class _MemorySettingsStore implements SettingsStore {
  SettingsDocument document = SettingsDocument();

  @override
  Future<SettingsDocument> read() async => document;

  @override
  Future<void> write(SettingsDocument document) async {
    this.document = document;
  }
}
