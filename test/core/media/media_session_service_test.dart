import 'dart:async';

import 'package:argo/core/media/media_session_service.dart';
import 'package:argo/core/media/media_state.dart';
import 'package:flutter_test/flutter_test.dart';

MediaSourceState source(String id, {int revision = 1, String? title}) =>
    MediaSourceState(
      id: id,
      kind: id.startsWith('projection')
          ? MediaSourceKind.androidAuto
          : MediaSourceKind.bluetooth,
      deviceId: 'device:$id',
      sessionId: id,
      details: MediaDetails(title: title),
      revision: revision,
      updatedAtMs: revision,
      commands: id.startsWith('bluetooth') ? ['play', 'pause'] : [],
    );

void main() {
  test(
    'provider leases isolate removal, replacement and stale revisions',
    () async {
      final media = CachedMediaSessionService();
      final aa = media.register('projection');
      final bt = media.register('bluetooth');
      aa.publish(1, [source('projection:1')]);
      bt.publish(1, [source('bluetooth:1', revision: 5, title: 'Fresh')]);
      aa.publish(2, []);
      expect(media.current.sources.single.details.title, 'Fresh');
      bt.publish(0, []);
      expect(media.current.sources, hasLength(1));
      bt.publish(2, [source('bluetooth:1', revision: 1, title: 'Stale')]);
      expect(media.current.sources.single.details.title, 'Fresh');
      final replacement = media.register('bluetooth');
      bt.publish(99, [source('bluetooth:old')]);
      bt.close();
      replacement.publish(1, [source('bluetooth:new')]);
      expect(media.current.sources.single.id, 'bluetooth:new');
      expect(() => aa.publish(3, [source('bluetooth:new')]), throwsStateError);
      replacement.close();
      expect(media.current.sources, isEmpty);
      await media.close();
    },
  );
  test('selection waits for audibility, targets current source and rejects late completion', () async {
    final media = CachedMediaSessionService();
    final aa = media.register('projection')
      ..publish(1, [source('projection:1')]);
    final bt = media.register('bluetooth')..publish(1, [source('bluetooth:1')]);
    final applied = Completer<void>();
    media.select = (_) => applied.future;
    final pending = media.selectSource('bluetooth:1');
    await Future<void>.delayed(Duration.zero);
    expect(media.current.activeSourceId, 'projection:1');
    applied.complete();
    await pending;
    expect(media.current.activeSourceId, 'bluetooth:1');
    final calls = <String>[];
    media.execute = (source, command) async =>
        calls.add('${source.id}:$command');
    await media.command('bluetooth:1', 'pause');
    expect(calls, ['bluetooth:1:pause']);
    await expectLater(
      media.command('projection:1', 'pause'),
      throwsUnsupportedError,
    );
    await expectLater(
      media.command('bluetooth:1', 'next'),
      throwsUnsupportedError,
    );
    final late = Completer<void>();
    media.select = (_) => late.future;
    final obsolete = media.selectSource('bluetooth:1');
    await Future<void>.delayed(Duration.zero);
    bt.close();
    late.complete();
    await expectLater(obsolete, throwsStateError);
    expect(media.current.activeSourceId, isNull);
    aa.close();
    await media.close();
  });
}
