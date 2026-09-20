import 'dart:async';

import 'package:argo/core/camera/camera_service.dart';
import 'package:argo/core/camera/parking_model_service.dart';
import 'package:argo/features/settings/models/model_manager_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class Control implements SurroundCameraControl {
  Completer<Map<String, dynamic>>? poll, download;
  final actions = <String>[];
  Map<String, dynamic> state() => {
    'models': [
      {
        'id': 'test',
        'display_name': 'Test model',
        'size_bytes': 1000,
        'input': {},
        'installed': false,
      },
    ],
    'progress': {},
  };
  @override
  Future<Map<String, dynamic>> command(
    String operation, [
    Map<String, Object?> arguments = const {},
    bool administration = false,
  ]) async {
    final action = arguments['action'] as String;
    actions.add(action);
    if (action == 'status' && poll != null) return poll!.future;
    if (action == 'download' && download != null) return download!.future;
    return state();
  }

  @override
  Future<void> selectView(
    String mode, {
    String? group,
    int? width,
    int? height,
  }) async {}
}

void main() {
  testWidgets(
    'foreground download bypasses stalled poll and rejects its late result',
    (tester) async {
      final control = Control();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ModelManagerPage(service: ParkingModelService(control)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      control.poll = Completer();
      await tester.pump(const Duration(seconds: 1));
      control.download = Completer();
      await tester.tap(find.text('Download'));
      await tester.pump();
      expect(control.actions.last, 'download');
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      control.download!.complete({
        ...control.state(),
        'progress': {'state': 'downloading'},
      });
      await tester.pump();
      control.poll!.complete({'models': [], 'progress': {}});
      await tester.pump();
      expect(find.text('Test model'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      expect(control.actions.last, 'cancel');
      await tester.pumpWidget(const SizedBox());
    },
  );
}
