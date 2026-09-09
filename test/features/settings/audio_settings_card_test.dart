import 'package:argo/features/settings/audio_settings_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'volume previews a drag, commits once and exposes host failures',
    (tester) async {
      final commits = <double>[];
      Future<void> show({bool fail = false}) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AudioSettingSlider(
              label: 'Volume',
              value: .3,
              minimum: 0,
              maximum: 1,
              percentage: true,
              enabled: true,
              commit: (value) async {
                commits.add(value);
                if (fail) throw StateError('Output disappeared');
              },
            ),
          ),
        ),
      );
      await show();
      final start = tester.widget<Slider>(find.byType(Slider));
      start.onChanged!(.6);
      await tester.pump();
      expect(tester.widget<Slider>(find.byType(Slider)).value, .6);
      expect(find.text('60%'), findsOneWidget);
      expect(commits, isEmpty);
      tester.widget<Slider>(find.byType(Slider)).onChangeEnd!(.6);
      await tester.pumpAndSettle();
      expect(commits, [.6]);
      await show(fail: true);
      tester.widget<Slider>(find.byType(Slider)).onChangeEnd!(.7);
      await tester.pumpAndSettle();
      expect(find.textContaining('Output disappeared'), findsOneWidget);
      expect(tester.widget<Slider>(find.byType(Slider)).value, .3);
    },
  );
}
