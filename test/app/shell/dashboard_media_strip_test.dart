import 'package:argo/app/shell/dashboard_media_strip.dart';
import 'package:argo/core/media/media_session_service.dart';
import 'package:argo/core/media/media_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
