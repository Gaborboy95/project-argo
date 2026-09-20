import 'projection_recovery.dart';
import '../diagnostics/service_failure.dart';

import 'dart:collection';

import '../media/media_state.dart';

import 'projection_types.dart';

final class ProjectionDevice {
  const ProjectionDevice({
    required this.id,
    required this.displayName,
    required this.protocol,
    required this.transport,
  });

  final String id;
  final String displayName;
  final ProjectionProtocol protocol;
  final ProjectionTransport transport;

  @override
  bool operator ==(Object other) =>
      other is ProjectionDevice &&
      id == other.id &&
      displayName == other.displayName &&
      protocol == other.protocol &&
      transport == other.transport;

  @override
  int get hashCode => Object.hash(id, displayName, protocol, transport);
}

final class ProjectionVideoStream {
  ProjectionVideoStream({
    required this.id,
    required this.sessionId,
    required this.role,
    required this.codec,
    required this.width,
    required this.height,
    required this.framesPerSecond,
    this.contentInsets = const ProjectionInsets(),
    this.safeInsets = const ProjectionInsets(),
    this.visible = true,
    this.focused = true,
    this.presentationRevision = 0,
    List<int>? nativeViewParameters,
  }) : nativeViewParameters = nativeViewParameters == null
           ? null
           : List.unmodifiable(nativeViewParameters) {
    if (nativeViewParameters != null &&
        (nativeViewParameters.length != 40 ||
            nativeViewParameters.any((v) => v < 0 || v > 255))) {
      throw ArgumentError("Invalid native projection descriptor");
    }
    if (id.trim().isEmpty || sessionId.trim().isEmpty) {
      throw ArgumentError(
        'Projection stream and session IDs must not be empty.',
      );
    }
    if (width <= 0 || height <= 0 || framesPerSecond <= 0) {
      throw ArgumentError(
        'Projection video dimensions and FPS must be positive.',
      );
    }
    contentInsets.validate(name: 'contentInsets');
    safeInsets.validate(name: 'safeInsets');
    if (contentInsets.left + contentInsets.right >= width ||
        contentInsets.top + contentInsets.bottom >= height) {
      throw ArgumentError('Projection content insets leave no usable surface.');
    }
  }

  final String id;
  final String sessionId;
  final ProjectionVideoRole role;
  final ProjectionVideoCodec codec;
  final int width;
  final int height;
  final int framesPerSecond;
  final ProjectionInsets contentInsets;
  final ProjectionInsets safeInsets;
  final bool visible;
  final bool focused;
  final int presentationRevision;
  final List<int>? nativeViewParameters;

  @override
  bool operator ==(Object other) =>
      other is ProjectionVideoStream &&
      id == other.id &&
      sessionId == other.sessionId &&
      role == other.role &&
      codec == other.codec &&
      width == other.width &&
      height == other.height &&
      framesPerSecond == other.framesPerSecond &&
      contentInsets == other.contentInsets &&
      safeInsets == other.safeInsets &&
      visible == other.visible &&
      focused == other.focused &&
      presentationRevision == other.presentationRevision &&
      (nativeViewParameters == null
          ? other.nativeViewParameters == null
          : other.nativeViewParameters != null &&
                _listEquals(
                  nativeViewParameters!,
                  other.nativeViewParameters!,
                ));

  @override
  int get hashCode => Object.hash(
    id,
    sessionId,
    role,
    codec,
    width,
    height,
    framesPerSecond,
    contentInsets,
    safeInsets,
    visible,
    focused,
    presentationRevision,
    nativeViewParameters == null ? null : Object.hashAll(nativeViewParameters!),
  );
}

final class ProjectionAudioStream {
  const ProjectionAudioStream({
    required this.id,
    required this.sessionId,
    required this.role,
    required this.active,
    required this.hasFocus,
    this.sampleRate,
    this.bitsPerSample,
    this.channelCount,
  });

  final String id;
  final String sessionId;
  final ProjectionAudioRole role;
  final bool active;
  final bool hasFocus;
  final int? sampleRate, bitsPerSample, channelCount;

  @override
  bool operator ==(Object other) =>
      other is ProjectionAudioStream &&
      id == other.id &&
      sessionId == other.sessionId &&
      role == other.role &&
      active == other.active &&
      hasFocus == other.hasFocus &&
      sampleRate == other.sampleRate &&
      bitsPerSample == other.bitsPerSample &&
      channelCount == other.channelCount;

  @override
  int get hashCode => Object.hash(
    id,
    sessionId,
    role,
    active,
    hasFocus,
    sampleRate,
    bitsPerSample,
    channelCount,
  );
}

final class ProjectionDucking {
  ProjectionDucking(double gain, int rampMs)
    : gain = gain.isFinite ? gain.clamp(0.0, 1.0) : 1.0,
      rampMs = rampMs.clamp(0, 2000);
  final double gain;
  final int rampMs;
  @override
  bool operator ==(Object other) =>
      other is ProjectionDucking &&
      gain == other.gain &&
      rampMs == other.rampMs;
  @override
  int get hashCode => Object.hash(gain, rampMs);
}

final class ProjectionSession {
  ProjectionSession({
    required this.id,
    required this.device,
    required this.state,
    Iterable<ProjectionVideoStream> videoStreams = const [],
    Iterable<ProjectionAudioStream> audioStreams = const [],
    this.failureMessage,
    this.metadata,
    this.hostReturnRevision = 0,
    this.phoneDucking,
  }) : videoStreams = List.unmodifiable(videoStreams),
       audioStreams = List.unmodifiable(audioStreams);

  final String id;
  final ProjectionDevice device;
  final ProjectionSessionState state;
  final List<ProjectionVideoStream> videoStreams;
  final List<ProjectionAudioStream> audioStreams;

  /// Session-scoped phone requests to relinquish presentation, not AV stops.
  final int hostReturnRevision;
  final ProjectionDucking? phoneDucking;
  final ProjectionSessionMetadata? metadata;
  final String? failureMessage;

  @override
  bool operator ==(Object other) =>
      other is ProjectionSession &&
      id == other.id &&
      device == other.device &&
      state == other.state &&
      failureMessage == other.failureMessage &&
      hostReturnRevision == other.hostReturnRevision &&
      phoneDucking == other.phoneDucking &&
      metadata == other.metadata &&
      _listEquals(videoStreams, other.videoStreams) &&
      _listEquals(audioStreams, other.audioStreams);

  @override
  int get hashCode => Object.hash(
    id,
    device,
    state,
    failureMessage,
    metadata,
    hostReturnRevision,
    phoneDucking,
    Object.hashAll(videoStreams),
    Object.hashAll(audioStreams),
  );
}

enum ProjectionAudioFailure {
  focus(
    'Projection audio focus is degraded. Audio synchronization will retry.',
  ),
  gain('Projection audio gain is degraded. Audio synchronization will retry.'),
  timeout(
    'Projection audio is not responding. Reconnect if it does not recover.',
  );

  const ProjectionAudioFailure(this.message);
  final String message;
  bool get retryable => true;
}

final class ProjectionSnapshot {
  ProjectionSnapshot({
    required this.backendAvailable,
    Iterable<ProjectionDevice> devices = const [],
    Iterable<ProjectionSession> sessions = const [],
    this.activeSessionId,
    this.failureMessage,
    this.audioFailure,
    this.failure,
    this.switchRecovery,
  }) : devices = UnmodifiableListView(List.of(devices)),
       sessions = UnmodifiableListView(List.of(sessions));

  const ProjectionSnapshot.disabled()
    : backendAvailable = false,
      devices = const [],
      sessions = const [],
      activeSessionId = null,
      failureMessage = null,
      audioFailure = null,
      failure = null,
      switchRecovery = null;

  final bool backendAvailable;
  final List<ProjectionDevice> devices;
  final List<ProjectionSession> sessions;
  final String? activeSessionId;
  final String? failureMessage;
  final ProjectionAudioFailure? audioFailure;
  final ServiceFailure? failure;
  final ProjectionSwitchRecovery? switchRecovery;

  ProjectionSession? get activeSession {
    final id = activeSessionId;
    if (id == null) return null;
    for (final session in sessions) {
      if (session.id == id) return session;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is ProjectionSnapshot &&
      backendAvailable == other.backendAvailable &&
      audioFailure == other.audioFailure &&
      failure == other.failure &&
      switchRecovery == other.switchRecovery &&
      activeSessionId == other.activeSessionId &&
      failureMessage == other.failureMessage &&
      _listEquals(devices, other.devices) &&
      _listEquals(sessions, other.sessions);

  @override
  int get hashCode => Object.hash(
    backendAvailable,
    audioFailure,
    failure,
    switchRecovery,
    activeSessionId,
    failureMessage,
    Object.hashAll(devices),
    Object.hashAll(sessions),
  );
}

bool _listEquals<T>(List<T> left, List<T> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
