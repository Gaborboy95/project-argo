import 'package:argo/features/camera/calibration/mat_setup_step.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('front/rear template shows only its required mat forms', (
    tester,
  ) async {
    final draft = <String, dynamic>{
      'template': 'front_rear_checkerboards',
      'mats': <String, dynamic>{},
      'vehicle': <String, dynamic>{},
      'cameras': <String, dynamic>{},
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MatSetupStep(draft: draft, changed: () {}),
          ),
        ),
      ),
    );
    expect(find.text('front mat'), findsWidgets);
    expect(find.text('rear mat'), findsWidgets);
    expect(find.text('left mat'), findsNothing);
    expect(find.text('right mat'), findsNothing);
    expect(find.text('First inner corner X forward (m)'), findsNothing);
  });
}
