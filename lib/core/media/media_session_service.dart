import 'dart:async';

import 'media_state.dart';

abstract interface class MediaSessionService {
  MediaSessionSnapshot get current;
  Stream<MediaSessionSnapshot> get changes;
}

/// Application-owned live state, never persisted in SettingsService.
final class CachedMediaSessionService implements MediaSessionService {
  MediaSessionSnapshot _current = MediaSessionSnapshot();
  final _changes = StreamController<MediaSessionSnapshot>.broadcast(sync: true);
  bool _closed = false;
  @override
  MediaSessionSnapshot get current => _current;
  @override
  Stream<MediaSessionSnapshot> get changes => _changes.stream;
  void replace(MediaSessionSnapshot value) {
    if (_closed || value == _current) return;
    _current = value;
    _changes.add(value);
  }

  Future<void> close() async {
    _closed = true;
    await _changes.close();
  }
}
