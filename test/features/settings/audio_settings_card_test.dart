import 'dart:io';

import 'package:argo/core/audio/audio_service.dart';
import 'package:argo/core/diagnostics/diagnostics_service.dart';
import 'package:argo/core/settings/app_setting_keys.dart';
import 'package:argo/core/settings/settings_service.dart';
import 'package:argo/core/settings/settings_store.dart';
import 'package:argo/features/settings/audio_settings_card.dart';
import 'package:argo/integrations/audio/pipewire_audio_backend.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'missing saved output keeps setup usable and prevents audio on another default until retry',
    (tester) async {
      final settings = await SettingsService.load(
        schema: AppSettingKeys.createSchema(),
        store: _AudioStore(),
      );
      var connected = false;
      var tones = 0;
      final calls = <String>[];
      final backend = PipeWireAudioBackend(
        processRunner: (exe, args) async {
          calls.add('$exe ${args.join(' ')}');
          if (exe == 'gst-launch-1.0') tones++;
          return ProcessResult(1, 0, switch (exe) {
            'pw-dump' =>
              '[{"id":8,"info":{"props":{"media.class":"Audio/Sink","node.name":"other.output","node.description":"Other speakers"}}}${connected ? ',{"id":42,"info":{"props":{"media.class":"Audio/Sink","node.name":"saved.output","node.description":"Saved speakers"}}}' : ''}]',
            _ => args.first == 'get-volume' ? 'Volume: 0.25' : '',
          }, '');
        },
      );
      final audio = await DefaultAudioService.start(
        backend: backend,
        settings: settings,
        diagnostics: DiagnosticsService(),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: AudioSettingsCard(audio: audio)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(audio.current.backendAvailable, isFalse);
      expect(find.text(audio.current.failure!.summary), findsOneWidget);
      expect(find.text('Other speakers'), findsOneWidget);
      expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Test tone · 2 seconds'),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(
              find.widgetWithText(TextButton, 'I heard the tone'),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(
              find.widgetWithText(TextButton, 'Refresh outputs'),
            )
            .onPressed,
        isNotNull,
      );
      expect(settings.get(AppSettingKeys.audioPreferredOutput), 'saved.output');
      expect(
        calls.any(
          (call) => call.contains('set-volume') || call.contains('set-mute'),
        ),
        isFalse,
      );
      connected = true;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(audio.current.backendAvailable, isTrue);
      expect(audio.current.failure, isNull);
      expect(calls, contains('wpctl set-default 42'));
      expect(find.text('Saved speakers'), findsOneWidget);
      expect(settings.get(AppSettingKeys.audioPreferredOutput), 'saved.output');
      final tone = find.widgetWithText(OutlinedButton, 'Test tone · 2 seconds');
      await tester.ensureVisible(tone);
      await tester.tap(tone);
      await tester.pumpAndSettle();
      expect(tones, 1);
      expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(audio.close);
      await settings.close();
    },
  );

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
      expect(find.text('Could not change the audio setting'), findsOneWidget);
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Output disappeared'), findsOneWidget);
      expect(
        find.text('Copy diagnostics (private content omitted)'),
        findsOneWidget,
      );
      expect(tester.widget<Slider>(find.byType(Slider)).value, .3);
    },
  );
}

class _AudioStore implements SettingsStore {
  @override
  Future<SettingsDocument> read() async => SettingsDocument(
    values: {
      AppSettingKeys.audioPreferredOutput.id: 'saved.output',
      AppSettingKeys.audioMasterVolume.id: .85,
    },
  );
  @override
  Future<void> write(SettingsDocument document) async {}
}
