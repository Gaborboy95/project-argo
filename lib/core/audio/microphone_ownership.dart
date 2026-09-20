enum MicrophoneOwnership {
  available,
  carPlay,
  androidAuto,
  bluetoothCall,
  localAssistant,
  unavailable,
  failed;

  static MicrophoneOwnership parse(Object? code) => switch (code) {
    'available' => available,
    'owned-by-carplay' => carPlay,
    'owned-by-android-auto' => androidAuto,
    'owned-by-bluetooth-call' => bluetoothCall,
    'owned-by-local-assistant' => localAssistant,
    'failed' => failed,
    _ => unavailable,
  };
  String get message => switch (this) {
    available => 'Microphone available',
    carPlay => 'Microphone currently in use by CarPlay',
    androidAuto => 'Microphone currently in use by Android Auto',
    bluetoothCall => 'Microphone currently in use by Bluetooth call',
    localAssistant => 'Microphone currently in use by local assistant',
    unavailable => 'Microphone ownership is unavailable',
    failed => 'Microphone ownership could not be checked',
  };
  bool get occupied =>
      this != available && this != unavailable && this != failed;
}
