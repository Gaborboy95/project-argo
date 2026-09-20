import 'dart:async';

import 'package:argo/core/audio/audio_service.dart';
import 'package:argo/core/audio/in_memory_audio_backend.dart';
import 'package:argo/core/diagnostics/diagnostics_service.dart';
import 'package:argo/core/settings/app_setting_keys.dart';
import 'package:argo/core/settings/settings_service.dart';
import 'package:argo/features/setup/setup_assistant.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../core/camera/camera_test.dart' show MemoryCameraSettings;

void main() {
  testWidgets(
    'setup persists progress, resumes and permits absent optional hardware',
    (tester) async {
      final settings = await SettingsService.load(
        schema: AppSettingKeys.createSchema(),
        store: MemoryCameraSettings(),
      );
      final audio = await DefaultAudioService.start(
        backend: InMemoryAudioBackend(),
        settings: settings,
        diagnostics: DiagnosticsService(),
      );
      Widget app() => MaterialApp(
        home: SetupAssistant(settings: settings, audio: audio),
      );
      await tester.pumpWidget(app());
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(settings.get(AppSettingKeys.setupStep), 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app());
      expect(find.text('Display & touch'), findsOneWidget);
      await tester.ensureVisible(find.text('Set up later'));
      await tester.tap(find.text('Set up later'));
      await tester.pumpAndSettle();
      expect(settings.get(AppSettingKeys.setupStep), 2);
      await tester.pumpWidget(const SizedBox());
      unawaited(audio.close());
      unawaited(settings.close());
      await tester.pump();
    },
  );
}
