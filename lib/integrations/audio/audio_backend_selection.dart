import 'dart:io';

import '../../core/audio/audio_backend.dart';
import '../../core/audio/audio_backend_type.dart';
import 'pipewire_audio_backend.dart';

AudioBackend selectAudioBackend({
  required Map<String, String> environment,
  bool? isLinux,
  AudioProcessRunner? processRunner,
}) {
  final type = AudioBackendType.fromEnvironment(environment);
  return switch (type) {
    AudioBackendType.disabled => const DisabledAudioBackend(),
    AudioBackendType.pipewire => _pipeWire(
      isLinux: isLinux ?? Platform.isLinux,
      processRunner: processRunner,
    ),
  };
}

AudioBackend _pipeWire({
  required bool isLinux,
  AudioProcessRunner? processRunner,
}) {
  if (!isLinux) {
    throw UnsupportedError(
      'ARGO_AUDIO_BACKEND=pipewire is supported only on Linux.',
    );
  }
  return PipeWireAudioBackend(processRunner: processRunner);
}
