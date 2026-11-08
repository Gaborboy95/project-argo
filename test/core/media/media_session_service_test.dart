import 'dart:async';

import 'package:argo/core/media/media_session_service.dart';
import 'package:argo/core/media/media_state.dart';
import 'package:flutter_test/flutter_test.dart';

MediaSourceState source(
  String id, {
  int revision = 1,
  String? title,
  MediaSourceKind? kind,
  String? sessionId,
  String? deviceId,
  List<String>? commands,
}) => MediaSourceState(
  id: id,
  kind:
      kind ??
      (id.startsWith('projection')
          ? MediaSourceKind.androidAuto
          : MediaSourceKind.bluetooth),
  deviceId: deviceId ?? 'device:$id',
  sessionId: sessionId ?? id,
  details: MediaDetails(title: title),
  revision: revision,
  updatedAtMs: revision,
  commands: commands ?? (id.startsWith('bluetooth') ? ['play', 'pause'] : []),
);

void main() {
  test(
    'AA, CarPlay and Bluetooth commands use only their own provider handlers',
    () async {
      final media = CachedMediaSessionService();
      final calls = <String>[];
      media.select = (source) async => calls.add('global.select:${source.id}');
      media.execute = (source, command) async =>
          calls.add('global.command:${source.id}:$command');
      MediaProvider register(String provider) => media.register(
        provider,
        select: (source) async => calls.add('$provider.select:${source.id}'),
        execute: (source, command) async =>
            calls.add('$provider.command:${source.id}:$command'),
      );
      final aa = register('aa')
        ..publish(1, [
          source(
            'AA',
            kind: MediaSourceKind.androidAuto,
            commands: ['playPause'],
          ),
        ]);
      final cp = register('cp')
        ..publish(1, [
          source('CP', kind: MediaSourceKind.carPlay, commands: ['playPause']),
        ]);
      final bt = register('bt')
        ..publish(1, [
          source(
            'BT',
            kind: MediaSourceKind.bluetooth,
            commands: ['play', 'pause'],
          ),
        ]);
      expect(media.current.activeSourceId, 'AA');
      await media.command('AA', 'playPause');
      await media.selectSource('CP');
      await media.command('CP', 'playPause');
      await media.selectSource('BT');
      await media.command('BT', 'pause');
      expect(calls, [
        'aa.command:AA:playPause',
        'cp.select:CP',
        'cp.command:CP:playPause',
        'bt.select:BT',
        'bt.command:BT:pause',
      ]);
      aa.close();
      cp.close();
      bt.close();
      await media.close();
    },
  );

  test('queued selection and control cannot move to a replacement provider lease with reused IDs', () async {
    final media = CachedMediaSessionService();
    final calls = <String>[];
    final gate = Completer<void>();
    final old = media.register(
      'phone',
      select: (source) async {
        calls.add('old.select');
        await gate.future;
      },
      execute: (source, command) async => calls.add('old.command'),
    );
    old.publish(1, [
      source(
        'same',
        kind: MediaSourceKind.androidAuto,
        commands: ['playPause'],
      ),
    ]);
    final first = media.selectSource('same');
    await Future<void>.delayed(Duration.zero);
    final queuedCommand = media.command('same', 'playPause');
    final queuedSelection = media.selectSource('same');
    final expectations = [
      expectLater(first, throwsStateError),
      expectLater(queuedCommand, throwsStateError),
      expectLater(queuedSelection, throwsStateError),
    ];
    final replacement = media.register(
      'phone',
      select: (source) async => calls.add('new.select'),
      execute: (source, command) async => calls.add('new.command'),
    );
    replacement.publish(1, [
      source(
        'same',
        kind: MediaSourceKind.androidAuto,
        commands: ['playPause'],
      ),
    ]);
    gate.complete();
    await Future.wait(expectations);
    expect(calls, ['old.select']);
    expect(media.current.activeSourceId, isNull);
    old.publish(99, [source('obsolete')]);
    old.close();
    await media.selectSource('same');
    await media.command('same', 'playPause');
    expect(calls, ['old.select', 'new.select', 'new.command']);
    replacement.close();
    await media.close();
  });

  test('queued operations capture device and session epochs before waiting for another selection', () async {
    for (final changeDevice in [false, true]) {
      final media = CachedMediaSessionService();
      final calls = <String>[];
      final gate = Completer<void>();
      final provider = media.register(
        'phone',
        select: (source) async {
          calls.add('select:${source.id}');
          if (source.id == 'blocker') await gate.future;
        },
        execute: (source, command) async => calls.add('command:${source.id}'),
      );
      MediaSourceState target({bool replaced = false}) => source(
        'target',
        kind: MediaSourceKind.androidAuto,
        commands: ['playPause'],
        revision: replaced ? 2 : 1,
        sessionId: replaced && !changeDevice ? 'session-new' : 'session-old',
        deviceId: replaced && changeDevice ? 'device-new' : 'device-old',
      );
      final blocker = source('blocker', kind: MediaSourceKind.bluetooth);
      provider.publish(1, [target(), blocker]);
      final blocking = media.selectSource('blocker');
      await Future<void>.delayed(Duration.zero);
      final command = media.command('target', 'playPause');
      final selection = media.selectSource('target');
      final expectations = [
        expectLater(command, throwsStateError),
        expectLater(selection, throwsStateError),
      ];
      provider.publish(2, [target(replaced: true), blocker]);
      expect(
        media.current.activeSourceId,
        isNull,
        reason: 'Changed identity must not inherit active selection',
      );
      gate.complete();
      await blocking;
      await Future.wait(expectations);
      expect(calls, ['select:blocker']);
      expect(media.current.activeSourceId, 'blocker');
      provider.close();
      await media.close();
    }
  });

  test('an in-flight selection cannot confirm a different device under the same source and session IDs', () async {
    final media = CachedMediaSessionService();
    final gate = Completer<void>();
    final provider = media.register('phone', select: (_) => gate.future);
    provider.publish(1, [
      source('same', kind: MediaSourceKind.androidAuto, deviceId: 'original'),
    ]);
    final selecting = media.selectSource('same');
    final rejected = expectLater(selecting, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    provider.publish(2, [
      source(
        'same',
        kind: MediaSourceKind.androidAuto,
        deviceId: 'replacement',
        revision: 2,
      ),
    ]);
    gate.complete();
    await rejected;
    expect(media.current.activeSourceId, isNull);
    provider.close();
    await media.close();
  });

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
