import 'package:argo/app/shell/dashboard_floating_media.dart';
import 'package:argo/core/media/media_session_service.dart';
import 'package:argo/core/media/media_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'the same floating surface follows the finger before release and preserves tolerant controls',
    (tester) async {
      final media = CachedMediaSessionService();
      final provider = media.register('test');
      provider.publish(1, [
        const MediaSourceState(
          id: 'phone',
          deviceId: 'device',
          sessionId: 'session',
          kind: MediaSourceKind.androidAuto,
          details: MediaDetails(
            title: 'Music',
            playback: MediaPlaybackState.playing,
          ),
          commands: ['pause'],
          revision: 1,
          updatedAtMs: 1,
        ),
      ]);
      var commands = 0;
      media.execute = (_, _) async {
        commands++;
      };
      var open = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => Align(
                alignment: Alignment.bottomCenter,
                child: SizedBox(
                  width: 700,
                  child: DashboardFloatingMedia(
                    collapsedHeight: 80,
                    expandedHeight: 400,
                    open: open,
                    onOpen: () => setState(() => open = true),
                    onClose: () => setState(() => open = false),
                    media: media,
                    scale: 1,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final surface = find.byKey(const ValueKey('floating-media-surface'));
      final element = tester.element(surface);
      expect(tester.getSize(surface).height, 80);
      final tap = await tester.startGesture(
        tester.getCenter(find.byTooltip('pause')),
      );
      await tap.moveBy(const Offset(3, 5));
      await tap.up();
      await tester.pumpAndSettle();
      expect(commands, 1);
      final drag = await tester.startGesture(
        tester.getCenter(find.byTooltip('pause')),
      );
      await drag.moveBy(const Offset(0, -60));
      await tester.pump();
      expect(tester.getSize(surface).height, greaterThan(80));
      expect(tester.getSize(surface).height, lessThan(400));
      expect(tester.element(surface), same(element));
      expect(commands, 1);
      await drag.moveBy(const Offset(0, -280));
      await drag.up();
      await tester.pumpAndSettle();
      expect(tester.getSize(surface).height, 400);
      expect(open, isTrue);
      expect(commands, 1);
      await tester.fling(find.byTooltip('pause'), const Offset(0, 150), 900);
      await tester.pumpAndSettle();
      expect(tester.getSize(surface).height, 80);
      expect(tester.element(surface), same(element));
      expect(open, isFalse);
      expect(commands, 1);
      await tester.pumpWidget(const SizedBox());
      provider.close();
      await tester.runAsync(media.close);
    },
  );
}
