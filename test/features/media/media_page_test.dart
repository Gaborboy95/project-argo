import 'dart:async';

import 'package:argo/core/media/media_session_service.dart';
import 'package:argo/core/media/media_state.dart';
import 'package:argo/core/projection/in_memory_projection_backend.dart';
import 'package:argo/core/projection/projection_models.dart';
import 'package:argo/core/projection/projection_service.dart';
import 'package:argo/core/projection/projection_types.dart';
import 'package:argo/features/media/media_page.dart';
import 'package:argo/features/media/widgets/now_playing_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _device = ProjectionDevice(
  id: 'phone',
  displayName: 'My phone',
  protocol: ProjectionProtocol.androidAuto,
  transport: ProjectionTransport.usb,
);

MediaSourceState _source({
  String id = 'aa',
  String sessionId = 'session',
  MediaSourceKind kind = MediaSourceKind.androidAuto,
  MediaDetails details = const MediaDetails(
    title: 'Midnight City',
    artist: 'M83',
    album: 'Hurry Up, We’re Dreaming',
    application: 'Spotify',
    playback: MediaPlaybackState.playing,
    positionMs: 12000,
    durationMs: 90000,
  ),
  List<String> commands = const ['previous', 'playPause', 'next'],
  PhoneDetails? phone,
}) => MediaSourceState(
  id: id,
  kind: kind,
  deviceId: 'phone',
  sessionId: sessionId,
  displayName: kind == MediaSourceKind.carPlay ? 'iPhone' : 'My phone',
  details: details,
  commands: commands,
  phone: phone,
  revision: 1,
  updatedAtMs: 1,
);

Widget _page(
  _DirectProjectionService projection, {
  _Media? media,
  VoidCallback? devices,
  double scale = 1,
}) => MaterialApp(
  theme: ThemeData.dark(useMaterial3: true),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(
    body: MediaPage(projection: projection, media: media, onDevices: devices),
  ),
);

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('empty and connecting states direct device actions to Devices', (
    tester,
  ) async {
    final backend = InMemoryProjectionBackend(
      initial: ProjectionSnapshot(backendAvailable: true),
    );
    final projection = _DirectProjectionService(backend);
    var devices = 0;
    await tester.pumpWidget(_page(projection, devices: () => devices++));
    expect(find.text('No media selected'), findsOneWidget);
    expect(find.text('Connect music'), findsNothing);
    expect(find.text('Disconnect music'), findsNothing);
    await _tap(tester, find.text('Open Devices'));
    expect(devices, 1);
    backend.emit(
      ProjectionSnapshot(
        backendAvailable: true,
        devices: const [_device],
        sessions: [
          ProjectionSession(
            id: 'session',
            device: _device,
            state: ProjectionSessionState.connecting,
          ),
        ],
      ),
    );
    await tester.pump();
    expect(find.text('Connecting to My phone'), findsOneWidget);
    backend.emit(
      ProjectionSnapshot(
        backendAvailable: true,
        devices: const [_device],
        sessions: [
          ProjectionSession(
            id: 'session',
            device: _device,
            state: ProjectionSessionState.streaming,
          ),
        ],
      ),
    );
    await tester.pump();
    expect(find.text('Ready to play'), findsOneWidget);
    expect(find.byTooltip('Play/pause'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await backend.close();
  });

  testWidgets(
    'hardware toggle targets the selected source and waits for reported playback',
    (tester) async {
      final backend = InMemoryProjectionBackend(
        initial: ProjectionSnapshot(backendAvailable: true),
      );
      final projection = _DirectProjectionService(backend);
      final media = _Media([_source()]);
      final pending = Completer<void>();
      media.operation = pending.future;
      await tester.pumpWidget(_page(projection, media: media));
      expect(media.commands, isEmpty);
      expect(find.text('Playing'), findsOneWidget);
      expect(find.byTooltip('play'), findsNothing);
      await tester.ensureVisible(find.byTooltip('Play/pause'));
      await tester.tap(find.byTooltip('Play/pause'));
      await tester.pump();
      expect(media.commands, [('aa', 'playPause')]);
      expect(find.text('Playing'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find
                  .ancestor(
                    of: find.byTooltip('Play/pause'),
                    matching: find.byType(IconButton),
                  )
                  .first,
            )
            .onPressed,
        isNull,
      );
      expect(find.byType(LinearProgressIndicator), findsNWidgets(2));
      pending.complete();
      await tester.pumpAndSettle();
      expect(find.text('Playing'), findsOneWidget);
      media.publish([
        _source(
          details: const MediaDetails(
            title: 'Midnight City',
            playback: MediaPlaybackState.paused,
          ),
        ),
      ]);
      await tester.pump();
      expect(find.text('Paused'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byTooltip('Play/pause'),
          matching: find.byIcon(Icons.play_arrow_rounded),
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      await media.events.close();
      await backend.close();
    },
  );

  testWidgets(
    'source selection uses phone labels and only supported transport controls',
    (tester) async {
      final backend = InMemoryProjectionBackend(
        initial: ProjectionSnapshot(backendAvailable: true),
      );
      final media = _Media([
        _source(),
        _source(
          id: 'cp',
          kind: MediaSourceKind.carPlay,
          commands: const ['previous', 'playPause'],
        ),
      ]);
      await tester.pumpWidget(
        _page(_DirectProjectionService(backend), media: media),
      );
      expect(media.selections, isEmpty);
      expect(find.textContaining('androidAuto'), findsNothing);
      await _tap(tester, find.byType(DropdownButtonFormField<String>));
      await _tap(tester, find.text('CarPlay · iPhone').last);
      expect(media.selections, ['cp']);
      expect(find.byTooltip('next'), findsNothing);
      await _tap(tester, find.byTooltip('previous'));
      expect(media.commands, [('cp', 'previous')]);
      await tester.pumpWidget(const SizedBox());
      await media.events.close();
      await backend.close();
    },
  );

  testWidgets(
    'reported track facts remain read-only and unknown facts are omitted',
    (tester) async {
      final backend = InMemoryProjectionBackend(
        initial: ProjectionSnapshot(backendAvailable: true),
      );
      final media = _Media([
        _source(
          details: const MediaDetails(
            title: 'Track',
            artist: 'Artist',
            album: 'Album',
            application: 'Player',
            positionMs: 12000,
            durationMs: 90000,
            playlist: 'Road trip',
            shuffle: true,
            repeatOne: true,
            rating: 83,
          ),
          phone: const PhoneDetails(
            batteryPercent: 73,
            charging: true,
            externalPower: true,
          ),
        ),
      ]);
      await tester.pumpWidget(
        _page(_DirectProjectionService(backend), media: media),
      );
      expect(find.text('0:12'), findsOneWidget);
      expect(find.text('1:30'), findsOneWidget);
      final progress = tester.widget<LinearProgressIndicator>(
        find.byKey(const ValueKey('media-reported-progress')),
      );
      expect(progress.value, closeTo(12 / 90, .0001));
      expect(find.byType(Slider), findsNothing);
      expect(find.text('Phone battery 73%'), findsOneWidget);
      expect(find.text('Charging'), findsOneWidget);
      expect(find.text('Plugged in'), findsNothing);
      expect(find.text('Playlist · Road trip'), findsOneWidget);
      expect(find.text('Shuffle on'), findsOneWidget);
      expect(find.text('Repeat one'), findsOneWidget);
      expect(find.textContaining('83'), findsNothing);
      expect(find.text('Playback state unavailable'), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      expect(find.text('0:12'), findsOneWidget);
      media.publish([
        _source(
          details: const MediaDetails(title: 'Different track'),
          commands: [],
        ),
      ]);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('media-reported-progress')),
        findsNothing,
      );
      expect(find.textContaining('Phone battery'), findsNothing);
      expect(find.text('Shuffle on'), findsNothing);
      expect(find.byTooltip('Play/pause'), findsNothing);
      expect(
        find.text('Playback controls are not available from this source.'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      await media.events.close();
      await backend.close();
    },
  );

  testWidgets(
    'provider and command errors preserve metadata and recover without command retries',
    (tester) async {
      final backend = InMemoryProjectionBackend(
        initial: ProjectionSnapshot(backendAvailable: true),
      );
      final media = _Media([_source()]);
      await tester.pumpWidget(
        _page(_DirectProjectionService(backend), media: media),
      );
      media.events.addError(StateError('lost observer'));
      await tester.pump();
      expect(
        find.text('Media information is temporarily unavailable.'),
        findsOneWidget,
      );
      expect(find.text('Midnight City'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find
                  .ancestor(
                    of: find.byTooltip('Play/pause'),
                    matching: find.byType(IconButton),
                  )
                  .first,
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
      media.publish([_source()]);
      await tester.pump();
      expect(
        find.text('Media information is temporarily unavailable.'),
        findsNothing,
      );
      media.rejectCommands = true;
      await _tap(tester, find.byTooltip('Play/pause'));
      expect(
        find.text('Could not control playback. Check the phone and try again.'),
        findsOneWidget,
      );
      expect(find.text('Playing'), findsOneWidget);
      expect(media.commands, [('aa', 'playPause')]);
      media.publish([]);
      await tester.pump();
      expect(find.text('Midnight City'), findsNothing);
      expect(find.text('No media selected'), findsOneWidget);
      expect(
        find.text('Could not control playback. Check the phone and try again.'),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      media.rejectCommands = false;
      final late = Completer<void>();
      media.operation = late.future;
      media.publish([_source()]);
      await tester.pump();
      await tester.ensureVisible(find.byTooltip('Play/pause'));
      await tester.tap(find.byTooltip('Play/pause'));
      await tester.pump();
      media.publish([
        _source(
          sessionId: 'replacement',
          details: const MediaDetails(title: 'Replacement track'),
        ),
      ]);
      late.completeError(StateError('Old session ended'));
      await tester.pumpAndSettle();
      expect(find.text('Replacement track'), findsOneWidget);
      expect(
        find.text('Could not control playback. Check the phone and try again.'),
        findsNothing,
      );
      expect(media.commands, [('aa', 'playPause'), ('aa', 'playPause')]);
      await tester.pumpWidget(const SizedBox());
      await media.events.close();
      await backend.close();
    },
  );

  testWidgets(
    'portrait, large text and short landscape retain usable transport targets',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final backend = InMemoryProjectionBackend(
        initial: ProjectionSnapshot(backendAvailable: true),
      );
      final media = _Media([_source()]);
      for (final entry in [
        (const Size(600, 800), 1.0),
        (const Size(320, 426), 2.0),
        (const Size(800, 260), 1.0),
        (const Size(240, 240), 1.0),
      ]) {
        tester.view.physicalSize = entry.$1;
        await tester.pumpWidget(
          _page(
            _DirectProjectionService(backend),
            media: media,
            scale: entry.$2,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        for (final tooltip in ['previous', 'Play/pause', 'next']) {
          final finder = find.byTooltip(tooltip);
          await tester.ensureVisible(finder);
          await tester.pumpAndSettle();
          final rect = tester.getRect(finder);
          expect(rect.width, greaterThanOrEqualTo(48));
          expect(rect.height, greaterThanOrEqualTo(48));
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(entry.$1.width));
          expect(finder.hitTestable(), findsOneWidget);
          await tester.tap(finder);
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
        expect(find.byType(NowPlayingPanel), findsOneWidget);
      }
      expect(media.commands.length, 12);
      await tester.pumpWidget(const SizedBox());
      await media.events.close();
      await backend.close();
    },
  );
}

class _Media implements MediaSessionService {
  _Media(List<MediaSourceState> sources)
    : current = MediaSessionSnapshot(
        sources: sources,
        activeSourceId: sources.firstOrNull?.id,
      );
  @override
  MediaSessionSnapshot current;
  final events = StreamController<MediaSessionSnapshot>.broadcast(sync: true);
  final commands = <(String, String)>[];
  final selections = <String>[];
  Future<void>? operation;
  bool rejectCommands = false;
  @override
  Stream<MediaSessionSnapshot> get changes => events.stream;
  void publish(List<MediaSourceState> sources) {
    current = MediaSessionSnapshot(
      sources: sources,
      activeSourceId: sources.any((s) => s.id == current.activeSourceId)
          ? current.activeSourceId
          : sources.firstOrNull?.id,
    );
    events.add(current);
  }

  @override
  Future<void> selectSource(String id) async {
    selections.add(id);
    current = MediaSessionSnapshot(
      sources: current.sources,
      activeSourceId: id,
    );
    events.add(current);
  }

  @override
  Future<void> command(String id, String command) async {
    commands.add((id, command));
    if (rejectCommands) throw StateError('phone rejected');
    await operation;
  }
}

final class _DirectProjectionService implements ProjectionService {
  _DirectProjectionService(this.backend);
  final InMemoryProjectionBackend backend;
  @override
  ProjectionSnapshot get current => backend.current;
  @override
  Stream<ProjectionSnapshot> get changes => backend.changes;
  @override
  Future<void> activate(String sessionId) => backend.activate(sessionId);
  @override
  Future<void> close() => backend.close();
  @override
  Future<void> connect(String deviceId) => backend.connect(deviceId);
  @override
  Future<void> disconnect(String sessionId) => backend.disconnect(sessionId);
  @override
  Future<void> sendButton(
    String sessionId,
    ProjectionInputButton button, {
    required bool pressed,
  }) => backend.sendButton(sessionId, button, pressed: pressed);
  @override
  Future<void> sendRotary(String sessionId, int detents) =>
      backend.sendRotary(sessionId, detents);
  @override
  Future<void> sendTouch(String sessionId, ProjectionTouch touch) =>
      backend.sendTouch(sessionId, touch);
  @override
  Future<void> setVideoVisibility(String streamId, bool visible) =>
      backend.setVideoVisibility(streamId, visible);
}
