/// Cached facts only: unknown values are null; times are integer milliseconds.
enum MediaSourceKind { androidAuto, carPlay, bluetooth, local }

enum MediaPlaybackState { unknown, stopped, playing, paused, error }

final class MediaDetails {
  const MediaDetails({
    this.title,
    this.artist,
    this.album,
    this.application,
    this.playback = MediaPlaybackState.unknown,
    this.positionMs,
    this.durationMs,
  });
  final String? title, artist, album, application;
  final MediaPlaybackState playback;
  final int? positionMs, durationMs;
  @override
  bool operator ==(Object other) =>
      other is MediaDetails &&
      title == other.title &&
      artist == other.artist &&
      album == other.album &&
      application == other.application &&
      playback == other.playback &&
      positionMs == other.positionMs &&
      durationMs == other.durationMs;
  @override
  int get hashCode => Object.hash(
    title,
    artist,
    album,
    application,
    playback,
    positionMs,
    durationMs,
  );
}

/// Phone battery is unrelated to vehicle battery; charging is not inferred.
final class PhoneDetails {
  const PhoneDetails({
    this.displayName,
    this.manufacturer,
    this.model,
    this.batteryPercent,
    this.criticalBattery,
  });
  final String? displayName, manufacturer, model;
  final int? batteryPercent;
  final bool? criticalBattery;
  bool? get charging => null;
  @override
  bool operator ==(Object other) =>
      other is PhoneDetails &&
      displayName == other.displayName &&
      manufacturer == other.manufacturer &&
      model == other.model &&
      batteryPercent == other.batteryPercent &&
      criticalBattery == other.criticalBattery;
  @override
  int get hashCode => Object.hash(
    displayName,
    manufacturer,
    model,
    batteryPercent,
    criticalBattery,
  );
}

/// Session ID is the epoch; a revision is meaningful only within that epoch.
/// updatedAtMs is daemon receive time (Unix UTC), not the phone's media clock.
final class ProjectionSessionMetadata {
  const ProjectionSessionMetadata({
    required this.revision,
    required this.updatedAtMs,
    this.media,
    this.phone = const PhoneDetails(),
  });
  final int revision, updatedAtMs;
  final MediaDetails? media;
  final PhoneDetails phone;
  @override
  bool operator ==(Object other) =>
      other is ProjectionSessionMetadata &&
      revision == other.revision &&
      updatedAtMs == other.updatedAtMs &&
      media == other.media &&
      phone == other.phone;
  @override
  int get hashCode => Object.hash(revision, updatedAtMs, media, phone);
}

final class MediaSourceState {
  const MediaSourceState({
    required this.id,
    required this.kind,
    required this.deviceId,
    required this.sessionId,
    required this.details,
    required this.revision,
    required this.updatedAtMs,
  });
  final String id, deviceId, sessionId;
  final MediaSourceKind kind;
  final MediaDetails details;
  final int revision, updatedAtMs;
  @override
  bool operator ==(Object other) =>
      other is MediaSourceState &&
      id == other.id &&
      kind == other.kind &&
      deviceId == other.deviceId &&
      sessionId == other.sessionId &&
      details == other.details;
  @override
  int get hashCode => Object.hash(id, kind, deviceId, sessionId, details);
}

final class MediaSessionSnapshot {
  MediaSessionSnapshot({
    Iterable<MediaSourceState> sources = const [],
    this.activeSourceId,
  }) : sources = List.unmodifiable(sources);
  final List<MediaSourceState> sources;
  final String? activeSourceId;
  MediaSourceState? get activeSource {
    for (final source in sources) {
      if (source.id == activeSourceId) return source;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is MediaSessionSnapshot &&
      activeSourceId == other.activeSourceId &&
      sources.length == other.sources.length &&
      List.generate(
        sources.length,
        (i) => sources[i] == other.sources[i],
      ).every((v) => v);
  @override
  int get hashCode => Object.hash(activeSourceId, Object.hashAll(sources));
}
