import 'package:argo/app/shell/dashboard_media_strip.dart';
import 'package:argo/core/media/media_session_service.dart';
import 'package:argo/core/media/media_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'compact player keeps readable metadata and full transport targets across dashboard sizes',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final media = CachedMediaSessionService();
      final provider = media.register('phone');
      provider.publish(1, [
        const MediaSourceState(
          id: 'phone',
          deviceId: 'phone',
          sessionId: 'session',
          kind: MediaSourceKind.androidAuto,
          details: MediaDetails(
            title: 'Midnight City',
            artist: 'M83',
            playback: MediaPlaybackState.playing,
          ),
          commands: ['previous', 'pause', 'next'],
          revision: 1,
          updatedAtMs: 1,
        ),
      ]);
      final commands = <String>[];
      media.execute = (_, command) async => commands.add(command);
      var opens = 0;
      for (final size in [
        const Size(1140, 96),
        const Size(570, 96),
        const Size(304, 96),
        const Size(280, 86),
        const Size(304, 58.8),
      ]) {
        tester.view.physicalSize = Size(size.width + 40, 600);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: size.width,
                  height: size.height,
                  child: DashboardMediaStrip(
                    media: media,
                    scale: 1.15,
                    onOpen: () => opens++,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Midnight City'), findsOneWidget);
        expect(find.text('M83'), findsOneWidget);
        final panel = tester.getRect(find.byType(DashboardMediaStrip));
        for (final command in ['previous', 'pause', 'next', 'Expand media']) {
          final control = tester.getRect(find.byTooltip(command));
          expect(control.width, greaterThanOrEqualTo(48));
          expect(control.height, greaterThanOrEqualTo(48));
          expect(control.left, greaterThanOrEqualTo(panel.left));
          expect(control.right, lessThanOrEqualTo(panel.right));
          await tester.tap(find.byTooltip(command));
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
      }
      expect(commands, [
        'previous',
        'pause',
        'next',
        'previous',
        'pause',
        'next',
        'previous',
        'pause',
        'next',
        'previous',
        'pause',
        'next',
        'previous',
        'pause',
        'next',
      ]);
      expect(opens, 5);
      await tester.pumpWidget(const SizedBox());
      provider.close();
      await tester.runAsync(media.close);
    },
  );

  testWidgets(
    'expanded media keeps transport controls within a narrow portrait panel',
    (tester) async {
      final media = CachedMediaSessionService();
      final provider = media.register('phone');
      provider.publish(1, [
        const MediaSourceState(
          id: 'phone',
          deviceId: 'device',
          sessionId: 'session',
          kind: MediaSourceKind.androidAuto,
          details: MediaDetails(title: 'Track', artist: 'Artist'),
          commands: ['previous', 'play', 'next'],
          revision: 1,
          updatedAtMs: 1,
        ),
      ]);
      final commands = <String>[];
      media.execute = (_, command) async => commands.add(command);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 240,
                height: 240,
                child: SingleChildScrollView(
                  child: DashboardMediaStrip(
                    media: media,
                    scale: 1.3,
                    expanded: true,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final panel = tester.getRect(find.byType(DashboardMediaStrip));
      for (final command in ['previous', 'play', 'next']) {
        final control = tester.getRect(find.byTooltip(command));
        expect(control.left, greaterThanOrEqualTo(panel.left));
        expect(control.right, lessThanOrEqualTo(panel.right));
        expect(find.byTooltip(command).hitTestable(), findsOneWidget);
        await tester.tap(find.byTooltip(command));
        await tester.pump();
      }
      expect(commands, ['previous', 'play', 'next']);
      await tester.pumpWidget(const SizedBox());
      provider.close();
      await tester.runAsync(media.close);
    },
  );

  testWidgets(
    'strip targets selected provider, omits unsupported commands and fits accessible text',
    (tester) async {
      final media = CachedMediaSessionService();
      final commands = <String>[];
      var opens = 0;
      media.execute = (source, command) async =>
          commands.add('${source.id}:$command');
      final provider = media.register('bluetooth');
      provider.publish(1, [
        const MediaSourceState(
          id: 'bt:phone',
          kind: MediaSourceKind.bluetooth,
          deviceId: 'opaque-device',
          sessionId: 'connection',
          details: MediaDetails(
            title: 'Track',
            artist: 'Artist',
            playback: MediaPlaybackState.playing,
          ),
          commands: ['pause'],
          revision: 1,
          updatedAtMs: 1,
        ),
      ]);
      media.reflectSelection('bt:phone');
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 480,
                  height: 48,
                  child: DashboardMediaStrip(
                    media: media,
                    scale: 1.3,
                    onOpen: () => opens++,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.textContaining('Track', findRichText: true), findsOneWidget);
      expect(find.textContaining('Artist', findRichText: true), findsOneWidget);
      expect(find.byTooltip('previous'), findsNothing);
      expect(find.byTooltip('play'), findsNothing);
      expect(find.byTooltip('next'), findsNothing);
      await tester.tap(find.byTooltip('pause'));
      await tester.pumpAndSettle();
      expect(commands, ['bt:phone:pause']);
      await tester.fling(find.byTooltip('pause'), const Offset(0, -80), 700);
      await tester.pumpAndSettle();
      expect(opens, 1);
      expect(commands, ['bt:phone:pause']);
      provider.close();
      await tester.pumpAndSettle();
      expect(find.byTooltip('pause'), findsNothing);
      expect(
        find.textContaining('No media selected', findRichText: true),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(media.close);
    },
  );
}
