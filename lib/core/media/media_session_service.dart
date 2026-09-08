import 'dart:async';

import 'media_state.dart';

abstract interface class MediaSessionService {
  MediaSessionSnapshot get current;
  Stream<MediaSessionSnapshot> get changes;
  Future<void> selectSource(String id);
  Future<void> command(String id, String command);
}

/// Each registration is a lease. An obsolete provider cannot update its successor.
final class MediaProvider {
  MediaProvider._(this.service, this.name);
  final CachedMediaSessionService service;
  final String name;
  int _revision = -1;
  List<MediaSourceState> _sources = [];
  void publish(int revision, Iterable<MediaSourceState> sources) {
    if (service._providers[name] != this || revision <= _revision) return;
    final incoming = sources.take(32).toList();
    if (incoming.map((s) => s.id).toSet().length != incoming.length) {
      throw StateError('Duplicate media source IDs');
    }
    final foreign = service._providers.values
        .where((p) => p != this)
        .expand((p) => p._sources)
        .map((s) => s.id)
        .toSet();
    if (incoming.any((s) => foreign.contains(s.id))) {
      throw StateError('Media source ID belongs to another provider');
    }
    _revision = revision;
    final previous = {for (final s in _sources) s.id: s};
    _sources = incoming.map((s) {
      final old = previous[s.id];
      return old != null &&
              old.sessionId == s.sessionId &&
              old.revision > s.revision
          ? old
          : s;
    }).toList();
    service._refresh();
  }

  void close() {
    if (service._providers[name] != this) return;
    service._providers.remove(name);
    service._refresh();
  }
}

/// Application-owned state and serialized selection; PCM never crosses this API.
final class CachedMediaSessionService implements MediaSessionService {
  MediaSessionSnapshot _current = MediaSessionSnapshot();
  final _changes = StreamController<MediaSessionSnapshot>.broadcast(sync: true);
  final _providers = <String, MediaProvider>{};
  bool _closed = false, _selectedOnce = false;
  Future<void>? _tail;
  int _pendingOperations = 0;
  Future<void> Function(MediaSourceState)? select;
  Future<void> Function(MediaSourceState, String)? execute;
  @override
  MediaSessionSnapshot get current => _current;
  @override
  Stream<MediaSessionSnapshot> get changes => _changes.stream;
  MediaProvider register(String name) {
    final provider = MediaProvider._(this, name);
    _providers[name] = provider;
    _refresh();
    return provider;
  }

  void _refresh() {
    final sources = _providers.values.expand((p) => p._sources).toList();
    var selected = sources.any((s) => s.id == _current.activeSourceId)
        ? _current.activeSourceId
        : null;
    if (!_selectedOnce && selected == null) {
      selected = sources
          .where(
            (s) =>
                s.kind == MediaSourceKind.androidAuto ||
                s.kind == MediaSourceKind.carPlay,
          )
          .firstOrNull
          ?.id;
      if (selected != null) _selectedOnce = true;
    }
    _emit(MediaSessionSnapshot(sources: sources, activeSourceId: selected));
  }

  void reflectSelection(String? id) {
    _selectedOnce = true;
    _emit(
      MediaSessionSnapshot(
        sources: _current.sources,
        activeSourceId: _current.sources.any((s) => s.id == id) ? id : null,
      ),
    );
  }

  void _emit(MediaSessionSnapshot value) {
    if (_closed || value == _current) return;
    _current = value;
    _changes.add(value);
  }

  Future<void> _serialize(Future<void> Function() operation) {
    if (_closed || _pendingOperations >= 8) {
      return Future.error(StateError('Media controls busy or closed'));
    }
    _pendingOperations++;
    final next = (_tail ?? Future<void>.value()).then((_) => operation());
    late final Future<void> settled;
    settled = next.catchError((Object _) {}).whenComplete(() {
      _pendingOperations--;
      if (identical(_tail, settled)) _tail = null;
    });
    _tail = settled;
    return next;
  }

  MediaSourceState _source(String id) =>
      _current.sources.where((s) => s.id == id).firstOrNull ??
      (throw StateError('Media source disconnected'));
  @override
  Future<void> selectSource(String id) => _serialize(() async {
    final source = _source(id);
    if (select == null) throw UnsupportedError('Media routing unavailable');
    await select!(source);
    if (_source(id).sessionId != source.sessionId) {
      throw StateError('Media session replaced');
    }
    reflectSelection(id);
  });
  @override
  Future<void> command(String id, String command) => _serialize(() async {
    final source = _source(id);
    if (_current.activeSourceId != id ||
        !source.commands.contains(command) ||
        execute == null) {
      throw UnsupportedError('Playback command unavailable for this source');
    }
    await execute!(source, command);
  });
  Future<void> close() async {
    _closed = true;
    if (_tail != null) await _tail;
    _providers.clear();
    await _changes.close();
  }
}
