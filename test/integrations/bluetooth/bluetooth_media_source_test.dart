import 'dart:async';

import 'package:argo/core/connectivity/connectivity_service.dart';
import 'package:argo/core/media/media_session_service.dart';
import 'package:argo/core/media/media_state.dart';
import 'package:argo/integrations/bluetooth/bluetooth_media_source.dart';
import 'package:flutter_test/flutter_test.dart';

class Connection implements ConnectivityService {
  final updates = StreamController<ConnectivitySnapshot>.broadcast(sync: true);
  @override
  ConnectivitySnapshot connectivity = const ConnectivitySnapshot();
  @override
  Stream<ConnectivitySnapshot> get connectivityChanges => updates.stream;
  final calls = <(String, String, int)>[];
  @override
  Future<void> connectivityCommand(
    String action, {
    String target = '',
    bool accept = false,
    int prompt = 0,
  }) async {
    calls.add((action, target, prompt));
  }

  void emit({
    String? id = 'bluetooth:1',
    String selected = 'projection',
    int operation = 0,
  }) {
    connectivity = ConnectivitySnapshot(
      available: true,
      music: {
        'selected': selected,
        'operation': operation,
        'source': id == null
            ? null
            : {
                'id': id,
                'session_id': id,
                'device_id': 'device',
                'name': 'Phone',
                'revision': 1,
                'updated_at_ms': 1,
                'commands': ['play', 'pause'],
                'title': 'Track',
                'artist': null,
                'album': null,
                'position_ms': null,
                'duration_ms': null,
                'playback': 'playing',
              },
      },
    );
    updates.add(connectivity);
  }
}

void main() {
  test('Bluetooth facts work without projection and commands wait for daemon acknowledgement', () async {
    final connection = Connection();
    final media = CachedMediaSessionService();
    final adapter = BluetoothMediaSource(connection, media);
    connection.emit();
    expect(media.current.sources.single.kind, MediaSourceKind.bluetooth);
    expect(media.current.sources.single.details.positionMs, isNull);
    expect(media.current.activeSourceId, isNull);
    final selecting = media.selectSource('bluetooth:1');
    await Future<void>.delayed(Duration.zero);
    final request = connection.calls.last;
    expect(request.$1, 'musicSelect');
    expect(request.$2, 'bluetooth:1');
    connection.emit(selected: 'bluetooth', operation: request.$3);
    await selecting;
    final play = media.command('bluetooth:1', 'play');
    await Future<void>.delayed(Duration.zero);
    expect(connection.calls.last.$1, 'musicPlay');
    expect(connection.calls.last.$2, 'bluetooth:1');
    connection.emit(selected: 'bluetooth', operation: connection.calls.last.$3);
    await play;
    connection.emit(id: null);
    expect(media.current.sources, isEmpty);
    await expectLater(media.command('bluetooth:1', 'play'), throwsStateError);
    connection.emit(id: 'bluetooth:2');
    expect(media.current.sources.single.sessionId, 'bluetooth:2');
    await adapter.close();
    await media.close();
    await connection.updates.close();
  });
}
