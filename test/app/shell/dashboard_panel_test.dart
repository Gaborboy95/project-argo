import 'package:argo/app/shell/dashboard_panel.dart';
import 'package:argo/app/shell/dashboard_temperature.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final kind in ['Media', 'Climate', 'Apps']) {
    testWidgets(
      '$kind panel tolerates taps, dismisses from controls and suppresses drag clicks',
      (tester) async {
        var taps = 0, closes = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                height: 400,
                child: DashboardPanel(
                  height: 400,
                  label: kind,
                  onDismiss: () => closes++,
                  child: Column(
                    children: [
                      SizedBox(
                        height: 100,
                        child: Center(
                          child: FilledButton(
                            onPressed: () => taps++,
                            child: Text(kind),
                          ),
                        ),
                      ),
                      const SizedBox(height: 600),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final center = tester.getCenter(find.text(kind));
        final small = await tester.startGesture(center);
        await small.moveBy(const Offset(5, 6));
        await small.up();
        await tester.pumpAndSettle();
        expect(taps, 1);
        expect(closes, 0);
        // Enough intent to cancel the button, but below dismissal threshold: snap back.
        final short = await tester.startGesture(center);
        await short.moveBy(const Offset(0, 28));
        await tester.pump(const Duration(milliseconds: 500));
        await short.up();
        await tester.pumpAndSettle();
        expect(taps, 1);
        expect(closes, 0);
        await tester.fling(find.text(kind), const Offset(0, 130), 800);
        await tester.pumpAndSettle();
        expect(taps, 1);
        expect(closes, 1);
      },
    );
  }
  testWidgets(
    'horizontal temperature owns adjustment, clamps and never becomes a panel drag',
    (tester) async {
      double value = 22;
      int closes = 0, opens = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => SizedBox(
                height: 400,
                child: DashboardPanel(
                  height: 400,
                  label: 'Climate',
                  onDismiss: () => closes++,
                  child: SizedBox(
                    height: 180,
                    child: DashboardTemperature(
                      side: 'Left',
                      value: value,
                      scale: 1,
                      onChange: (v) => setState(() => value = v),
                      onTap: () => opens++,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final target = find.byKey(const ValueKey('temperature-Left'));
      final drag = await tester.startGesture(tester.getCenter(target));
      await drag.moveBy(const Offset(25, 2));
      await drag.moveBy(const Offset(320, 2));
      await drag.up();
      await tester.pumpAndSettle();
      expect(value, 26);
      expect(closes, 0);
      expect(opens, 0);
      await tester.tap(find.byTooltip('Left cooler'));
      await tester.pump();
      expect(value, 25.5);
      await tester.tap(target);
      await tester.pump();
      expect(opens, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
