import 'dart:async';

import 'package:argo/core/projection/projection_backend.dart';
import 'package:argo/core/audio/audio_service.dart';
import 'package:argo/core/audio/audio_snapshot.dart';
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

  test(
    'phone duck composes with other focus and teardown restores only its lease',
    () async {
      final fixture = await _Fixture.start();
      await fixture.audio.registerSource(
        AudioSource(id: 'player', role: AudioSourceRole.media),
      );
      await fixture.audio.setSourceActive('player', true);
      await fixture.audio.registerSource(
        AudioSource(id: 'call', role: AudioSourceRole.communication),
      );
      final master = fixture.audio.current.masterVolume;
      fixture.backend.emit(
        _snapshot(
          audioRole: ProjectionAudioRole.media,
          phoneDucking: ProjectionDucking(.2, 0),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(fixture.audioBackend.sourceGains['player'], closeTo(.2, .0001));
      final call = await fixture.audio.requestFocus('call', duckingGain: .3);
      expect(fixture.audioBackend.sourceGains['player'], closeTo(.06, .0001));
      fixture.backend.emit(ProjectionSnapshot(backendAvailable: true));
      await Future<void>.delayed(Duration.zero);
      expect(fixture.audioBackend.sourceGains['player'], closeTo(.3, .0001));
      expect(fixture.audio.current.masterVolume, master);
      await call.release();
      expect(fixture.audioBackend.sourceGains['player'], 1);
      await fixture.close();
    },
  );
  test('phone ramp is bounded and cannot revive a torn down session', () async {
    final fixture = await _Fixture.start();
    await fixture.audio.registerSource(
      AudioSource(id: 'player', role: AudioSourceRole.media),
    );
    await fixture.audio.setSourceActive('player', true);
    expect(ProjectionDucking(-100, 99999).gain, 0);
    expect(ProjectionDucking(-100, 99999).rampMs, 2000);
    fixture.backend.emit(
      _snapshot(
        audioRole: ProjectionAudioRole.media,
        phoneDucking: ProjectionDucking(.1, 80),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(fixture.audioBackend.sourceGains['player'], closeTo(.1, .0001));
    fixture.backend.emit(ProjectionSnapshot(backendAvailable: true));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(fixture.audioBackend.sourceGains['player'], 1);
    await fixture.close();
  });

  test('gain failure cannot suppress authoritative projection state', () async {
    final gains = _ControlledGains()..failure = StateError('gain unavailable');
    final fixture = await _Fixture.start(gains: gains);
    final snapshot = _snapshot(audioRole: ProjectionAudioRole.speech);
    fixture.backend.emit(snapshot);
    await Future<void>.delayed(Duration.zero);
    expect(fixture.projection.current.sessions, snapshot.sessions);
    expect(fixture.projection.current.activeSessionId, 'session');
    expect(
      fixture.projection.current.audioFailure,
      ProjectionAudioFailure.gain,
    );
    await fixture.close();
  });

  test(
    'stalled gains do not queue obsolete snapshots or delay shutdown',
    () async {
      final gains = _ControlledGains()..pending = Completer<void>();
      final fixture = await _Fixture.start(gains: gains);
      fixture.backend.emit(_snapshot(audioRole: ProjectionAudioRole.speech));
      await Future<void>.delayed(Duration.zero);
      expect(gains.calls, ['session/speech']);
      for (var i = 0; i < 100; i++) {
        fixture.backend.emit(
          _snapshot(
            audioRole: ProjectionAudioRole.media,
            sessionId: 'replacement-$i',
          ),
        );
      }
      final empty = ProjectionSnapshot(backendAvailable: true);
      fixture.backend.emit(empty);
      await Future<void>.delayed(Duration.zero);
      expect(fixture.projection.current.sessions, isEmpty);
      expect(fixture.audio.current.focusSources, isEmpty);
      expect(gains.calls, ['session/speech']);
      await fixture.close().timeout(const Duration(seconds: 1));
      gains.pending!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(gains.calls, ['session/speech']);
    },
  );

  test('gain deadline remains bounded and retries the newest state', () async {
    final gains = _ControlledGains()..pending = Completer<void>();
    final fixture = await _Fixture.start(gains: gains);
    final timedOut = fixture.projection.changes.firstWhere(
      (state) => state.audioFailure == ProjectionAudioFailure.timeout,
    );
    fixture.backend.emit(_snapshot(audioRole: ProjectionAudioRole.media));
    await timedOut.timeout(const Duration(seconds: 5));
    for (var i = 0; i < 100; i++) {
      fixture.backend.emit(
        _snapshot(audioRole: ProjectionAudioRole.media, sessionId: 'latest-$i'),
      );
    }
    await Future<void>.delayed(Duration.zero);
    expect(gains.calls, ['session/speech']);
    expect(fixture.projection.current.activeSessionId, 'latest-99');
    final recovered = fixture.projection.changes.firstWhere(
      (state) => state.audioFailure == null,
    );
    gains.pending!.complete();
    await recovered.timeout(const Duration(seconds: 5));
    expect(gains.calls.last, 'latest-99/speech');
    expect(
      gains.calls.every(
        (id) => id == 'session/speech' || id == 'latest-99/speech',
      ),
      isTrue,
    );
    await fixture.close().timeout(const Duration(seconds: 1));
  });

  test('failed gain retries without another backend snapshot', () async {
    final gains = _ControlledGains()..failure = StateError('gain unavailable');
    final fixture = await _Fixture.start(gains: gains);
    final failed = fixture.projection.changes.firstWhere(
      (state) => state.audioFailure == ProjectionAudioFailure.gain,
    );
    fixture.backend.emit(_snapshot(audioRole: ProjectionAudioRole.media));
    await failed;
    gains.failure = null;
    await fixture.projection.changes
        .firstWhere((state) => state.audioFailure == null)
        .timeout(const Duration(seconds: 5));
    await fixture.close().timeout(const Duration(seconds: 1));
  });

  test('one failing cleanup cannot retain another obsolete owner', () async {
    final focus = _ControlledAudio();
    final fixture = await _Fixture.start(focus: focus);
    final first = _snapshot(audioRole: ProjectionAudioRole.speech);
    final second = _snapshot(
      audioRole: ProjectionAudioRole.media,
      sessionId: 'second',
    );
    fixture.backend.emit(
      ProjectionSnapshot(
        backendAvailable: true,
        sessions: [...first.sessions, ...second.sessions],
      ),
    );
    await Future<void>.delayed(Duration.zero);
    focus.failRelease = 'projection.session.speech';
    focus.failUnregister = 'projection.session.speech';
    fixture.backend.emit(ProjectionSnapshot(backendAvailable: true));
    await Future<void>.delayed(Duration.zero);
    expect(
      focus.unregistered,
      containsAll(['projection.session.speech', 'projection.second.speech']),
    );
    expect(
      fixture.audio.current.focusSources,
      isNot(contains('projection.second.speech')),
    );
    expect(
      fixture.projection.current.audioFailure,
      ProjectionAudioFailure.focus,
    );
    focus.failRelease = focus.failUnregister = null;
    await fixture.close();
    expect(focus.delegate.current.focusSources, isEmpty);
  });

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

ProjectionSnapshot _snapshot({
  required ProjectionAudioRole audioRole,
  String sessionId = 'session',
  ProjectionDucking? phoneDucking,
}) {
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
        id: sessionId,
        device: device,
        state: ProjectionSessionState.streaming,
        phoneDucking: phoneDucking,
        audioStreams: [
          ProjectionAudioStream(
            id: 'speech',
            sessionId: sessionId,
            role: audioRole,
            active: true,
            hasFocus: true,
          ),
        ],
      ),
    ],
    activeSessionId: sessionId,
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

  static Future<_Fixture> start({
    _ControlledGains? gains,
    _ControlledAudio? focus,
  }) async {
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
    if (gains != null) gains.delegate = backend;
    if (focus != null) focus.delegate = audio;
    final projection = await DefaultProjectionService.start(
      backend: gains ?? backend,
      audio: focus ?? audio,
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

class _ControlledGains extends Fake implements ProjectionBackend {
  late InMemoryProjectionBackend delegate;
  Completer<void>? pending;
  Object? failure;
  final calls = <String>[];
  @override
  ProjectionSnapshot get current => delegate.current;
  @override
  Stream<ProjectionSnapshot> get changes => delegate.changes;
  @override
  Future<void> start() => delegate.start();
  @override
  Future<void> close() => delegate.close();
  @override
  Future<void> setAudioGain(
    String sessionId,
    String streamId,
    double gain,
  ) async {
    calls.add('$sessionId/$streamId');
    if (failure case final error?) throw error;
    await pending?.future;
  }
}

class _ControlledAudio extends Fake implements AudioService {
  late AudioService delegate;
  String? failRelease, failUnregister;
  final unregistered = <String>[];
  @override
  AudioSnapshot get current => delegate.current;
  @override
  Stream<AudioSnapshot> get changes => delegate.changes;
  @override
  Future<void> registerSource(AudioSource source) =>
      delegate.registerSource(source);
  @override
  Future<void> setSourceActive(String id, bool active) =>
      delegate.setSourceActive(id, active);
  @override
  Future<AudioFocusHandle> requestFocus(
    String id, {
    double? duckingGain,
  }) async => _ControlledHandle(
    await delegate.requestFocus(id, duckingGain: duckingGain),
    () => failRelease == id,
  );
  @override
  Future<void> unregisterSource(String id) async {
    unregistered.add(id);
    if (failUnregister == id) throw StateError('unregister failed');
    await delegate.unregisterSource(id);
  }
}

class _ControlledHandle implements AudioFocusHandle {
  _ControlledHandle(this.delegate, this.fail);
  final AudioFocusHandle delegate;
  final bool Function() fail;
  @override
  Future<void> release() async {
    if (fail()) throw StateError('release failed');
    await delegate.release();
  }
}
