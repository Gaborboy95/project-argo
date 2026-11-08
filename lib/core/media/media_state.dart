/// Cached facts only: unknown values are null; times are integer milliseconds.
enum MediaSourceKind { androidAuto, carPlay, bluetooth, local }

enum MediaPlaybackState { unknown, stopped, playing, paused, error, seeking }

final class MediaDetails {
  const MediaDetails({
    this.title,
    this.artist,
    this.album,
    this.artworkPath,
    this.application,
    this.playback = MediaPlaybackState.unknown,
    this.positionMs,
    this.durationMs,
    this.playlist,
    this.shuffle,
    this.repeat,
    this.repeatOne,
    this.rating,
    this.albumArtist,
    this.genre,
    this.applicationId,
    this.trackId,
  });
  final String? title, artist, album, application, artworkPath;
  final MediaPlaybackState playback;
  final int? positionMs, durationMs;
  final String? playlist;
  final bool? shuffle, repeat, repeatOne;

  /// Raw provider value; no rating scale is inferred.
  final int? rating;
  final String? albumArtist, genre, applicationId, trackId;
  @override
  bool operator ==(Object other) =>
      other is MediaDetails &&
      title == other.title &&
      artist == other.artist &&
      album == other.album &&
      artworkPath == other.artworkPath &&
      application == other.application &&
      playback == other.playback &&
      positionMs == other.positionMs &&
      durationMs == other.durationMs &&
      playlist == other.playlist &&
      shuffle == other.shuffle &&
      repeat == other.repeat &&
      repeatOne == other.repeatOne &&
      rating == other.rating &&
      albumArtist == other.albumArtist &&
      genre == other.genre &&
      applicationId == other.applicationId &&
      trackId == other.trackId;
  @override
  int get hashCode => Object.hash(
    title,
    artist,
    album,
    artworkPath,
    application,
    playback,
    positionMs,
    durationMs,
    playlist,
    shuffle,
    repeat,
    repeatOne,
    rating,
    albumArtist,
    genre,
    applicationId,
    trackId,
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
    this.charging,
    this.externalPower,
  });
  final String? displayName, manufacturer, model;
  final int? batteryPercent;
  final bool? criticalBattery;
  final bool? charging;
  final bool? externalPower;
  @override
  bool operator ==(Object other) =>
      other is PhoneDetails &&
      displayName == other.displayName &&
      manufacturer == other.manufacturer &&
      model == other.model &&
      batteryPercent == other.batteryPercent &&
      criticalBattery == other.criticalBattery &&
      charging == other.charging &&
      externalPower == other.externalPower;
  @override
  int get hashCode => Object.hash(
    displayName,
    manufacturer,
    model,
    batteryPercent,
    criticalBattery,
    charging,
    externalPower,
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
    this.mediaCommands = const [],
  });
  final int revision, updatedAtMs;
  final MediaDetails? media;
  final PhoneDetails phone;
  final List<String> mediaCommands;
  @override
  bool operator ==(Object other) =>
      other is ProjectionSessionMetadata &&
      revision == other.revision &&
      updatedAtMs == other.updatedAtMs &&
      media == other.media &&
      phone == other.phone &&
      mediaCommands.join(',') == other.mediaCommands.join(',');
  @override
  int get hashCode =>
      Object.hash(revision, updatedAtMs, media, phone, mediaCommands.join(','));
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
    this.commands = const [],
    this.displayName,
    this.phone,
  });
  final List<String> commands;
  final String? displayName;
  final PhoneDetails? phone;
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
      details == other.details &&
      displayName == other.displayName &&
      phone == other.phone &&
      revision == other.revision &&
      updatedAtMs == other.updatedAtMs &&
      commands.join(',') == other.commands.join(',');
  @override
  int get hashCode => Object.hash(
    id,
    kind,
    deviceId,
    sessionId,
    details,
    displayName,
    phone,
    revision,
    updatedAtMs,
    commands.join(','),
  );
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
