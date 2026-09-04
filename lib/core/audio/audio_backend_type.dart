enum AudioBackendType {
  disabled('disabled'),
  pipewire('pipewire');

  const AudioBackendType(this.wireValue);
  final String wireValue;

  static AudioBackendType fromEnvironment(Map<String, String> environment) {
    final value = environment['ARGO_AUDIO_BACKEND']?.trim();
    if (value == null || value.isEmpty) return disabled;
    for (final backend in values) {
      if (backend.wireValue == value) return backend;
    }
    throw FormatException(
      'Invalid ARGO_AUDIO_BACKEND "$value"; expected disabled or pipewire.',
    );
  }
}
