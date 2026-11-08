import 'package:argo/core/projection/projection_preferences.dart';
import 'package:argo/core/projection/projection_settings_service.dart';
import 'package:argo/core/settings/app_setting_keys.dart';
import 'package:argo/core/settings/settings_service.dart';
import 'package:argo/core/settings/settings_store.dart';
import 'package:argo/features/settings/projection_settings_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'portrait scaling note follows effective density without editing the saved request',
    (tester) async {
      final store = _Store();
      final settings = await SettingsService.load(
        schema: AppSettingKeys.createSchema(),
        store: store,
      );
      for (final dpi in [160, 120]) {
        final service = ProjectionSettingsService(
          settings: settings,
          requested: ProjectionPreferences.defaults().copyWith(dpi: dpi),
        );
        service.setViewport(600, 720, 96);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: ProjectionSettingsCard(service: service),
              ),
            ),
          ),
        );
        final note = find.text(
          'Portrait scaling is adjusted to improve map touch.',
        );
        expect(note, dpi == 160 ? findsOneWidget : findsNothing);
        expect(
          tester
              .widget<TextFormField>(
                find.byKey(ValueKey('projection-dpi-$dpi')),
              )
              .initialValue,
          '$dpi',
        );
        service.setViewport(720, 720, 96);
        await tester.pump();
        expect(note, findsNothing);
        expect(service.effective.dpi, dpi);
        expect(store.writes, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await service.close();
      }
      await settings.close();
    },
  );
}

class _Store implements SettingsStore {
  var writes = 0;
  @override
  Future<SettingsDocument> read() async => SettingsDocument();
  @override
  Future<void> write(SettingsDocument document) async {
    writes++;
  }
}
