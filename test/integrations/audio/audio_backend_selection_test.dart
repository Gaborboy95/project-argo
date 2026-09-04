import 'dart:io';

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
