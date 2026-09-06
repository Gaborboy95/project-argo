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
  }) {
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
      focused == other.focused;

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

final class ProjectionSession {
  ProjectionSession({
    required this.id,
    required this.device,
    required this.state,
    Iterable<ProjectionVideoStream> videoStreams = const [],
    Iterable<ProjectionAudioStream> audioStreams = const [],
    this.failureMessage,
    this.metadata,
  }) : videoStreams = List.unmodifiable(videoStreams),
       audioStreams = List.unmodifiable(audioStreams);

  final String id;
  final ProjectionDevice device;
  final ProjectionSessionState state;
  final List<ProjectionVideoStream> videoStreams;
  final List<ProjectionAudioStream> audioStreams;
  final ProjectionSessionMetadata? metadata;
  final String? failureMessage;

  @override
  bool operator ==(Object other) =>
      other is ProjectionSession &&
      id == other.id &&
      device == other.device &&
      state == other.state &&
      failureMessage == other.failureMessage &&
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
    Object.hashAll(videoStreams),
    Object.hashAll(audioStreams),
  );
}

final class ProjectionSnapshot {
  ProjectionSnapshot({
    required this.backendAvailable,
    Iterable<ProjectionDevice> devices = const [],
    Iterable<ProjectionSession> sessions = const [],
    this.activeSessionId,
    this.failureMessage,
  }) : devices = UnmodifiableListView(List.of(devices)),
       sessions = UnmodifiableListView(List.of(sessions));

  const ProjectionSnapshot.disabled()
    : backendAvailable = false,
      devices = const [],
      sessions = const [],
      activeSessionId = null,
      failureMessage = null;

  final bool backendAvailable;
  final List<ProjectionDevice> devices;
  final List<ProjectionSession> sessions;
  final String? activeSessionId;
  final String? failureMessage;

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
      activeSessionId == other.activeSessionId &&
      failureMessage == other.failureMessage &&
      _listEquals(devices, other.devices) &&
      _listEquals(sessions, other.sessions);

  @override
  int get hashCode => Object.hash(
    backendAvailable,
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
