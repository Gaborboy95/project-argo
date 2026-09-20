import 'dart:io';

import 'package:argo/core/audio/audio_service.dart';
import 'package:argo/core/diagnostics/diagnostics_service.dart';
import 'package:argo/core/settings/app_setting_keys.dart';
import 'package:argo/core/settings/settings_service.dart';

import '../../core/camera/camera_test.dart' show MemoryCameraSettings;

import 'package:argo/core/audio/audio_backend.dart';
import 'package:argo/core/audio/audio_backend_type.dart';
import 'package:argo/integrations/audio/audio_backend_selection.dart';
import 'package:argo/integrations/audio/pipewire_audio_backend.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('disabled is the safe default', () {
    expect(
      AudioBackendType.fromEnvironment(const {}),
      AudioBackendType.disabled,
    );
    expect(
      selectAudioBackend(environment: const {}, isLinux: true),
      isA<DisabledAudioBackend>(),
    );
  });

  test('unknown backend fails clearly', () {
    expect(
      () => AudioBackendType.fromEnvironment(const {
        'ARGO_AUDIO_BACKEND': 'alsa',
      }),
      throwsFormatException,
    );
  });

  test('PipeWire is rejected on unsupported platforms', () {
    expect(
      () => selectAudioBackend(
        environment: const {'ARGO_AUDIO_BACKEND': 'pipewire'},
        isLinux: false,
      ),
      throwsUnsupportedError,
    );
  });

  test('PipeWire invokes fixed wpctl volume and mute operations', () async {
    final calls = <(String, List<String>)>[];
    final backend = PipeWireAudioBackend(
      processRunner: (executable, arguments) async {
        calls.add((executable, List.of(arguments)));
        final stdout = switch (arguments.first) {
          'get-volume' => 'Volume: 0.42 [MUTED]',
          'inspect' => 'audio.position = "[ FL, FR ]"',
          _ => '',
        };
        return ProcessResult(1, 0, stdout, '');
      },
    );
    addTearDown(backend.close);

    await backend.start();
    expect(backend.current.masterVolume, 0.42);
    expect(backend.current.muted, isTrue);
    await backend.setMasterVolume(0.75);
    await backend.setMuted(false);

    expect(
      calls.any(
        (call) =>
            call.$1 == 'wpctl' &&
            call.$2.join(' ') ==
                'set-volume @DEFAULT_AUDIO_SINK@ 0.750000 --limit 1.0',
      ),
      isTrue,
    );
    expect(
      calls.any(
        (call) =>
            call.$1 == 'wpctl' &&
            call.$2.join(' ') == 'set-mute @DEFAULT_AUDIO_SINK@ 0',
      ),
      isTrue,
    );
  });

  test('output discovery and tone never raise volume; selection re-resolves stable identity', () async {
    final calls = <String>[];
    var nodeId = 42;
    final backend = PipeWireAudioBackend(
      processRunner: (exe, args) async {
        calls.add('$exe ${args.join(' ')}');
        return ProcessResult(1, 0, switch (exe) {
          'pw-dump' =>
            '[{"id":$nodeId,"info":{"props":{"media.class":"Audio/Sink","node.name":"usb.dac","node.description":"USB sound"}}}]',
          _ => args.first == 'get-volume' ? 'Volume: 0.07 [MUTED]' : '',
        }, '');
      },
    );
    final settings = await SettingsService.load(
      schema: AppSettingKeys.createSchema(),
      store: MemoryCameraSettings(),
    );
    final audio = await DefaultAudioService.start(
      backend: backend,
      settings: settings,
      diagnostics: DiagnosticsService(),
    );
    addTearDown(audio.close);
    addTearDown(settings.close);
    expect(audio.current.masterVolume, .07);
    expect(audio.current.muted, isTrue);
    expect((await backend.discoverOutputs()).single.name, 'USB sound');
    nodeId = 55;
    await audio.selectOutput('usb.dac');
    expect(calls, contains('wpctl set-default 55'));
    await backend.testOutput();
    expect(calls.last, contains('volume=0.03'));
    expect(calls.last, contains('num-buffers=200'));
    expect(
      calls.any((c) => c.contains('set-volume') || c.contains('set-mute')),
      isFalse,
    );
    await expectLater(backend.selectOutput('missing'), throwsStateError);
    expect(calls.where((c) => c.startsWith('wpctl set-default')), hasLength(1));
  });

  test('PipeWire command failure includes stderr', () async {
    final backend = PipeWireAudioBackend(
      processRunner: (_, _) async =>
          ProcessResult(1, 2, '', 'server unavailable'),
    );
    await expectLater(
      backend.start(),
      throwsA(
        isA<AudioBackendCommandException>().having(
          (error) => error.toString(),
          'message',
          contains('server unavailable'),
        ),
      ),
    );
    await backend.close();
  });
}
