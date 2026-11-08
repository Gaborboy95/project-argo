import 'dart:async';

import 'package:argo/core/projection/projection_configuration.dart';
import 'package:argo/core/projection/projection_preferences.dart';
import 'package:argo/core/projection/projection_settings_service.dart';
import 'package:argo/core/settings/app_setting_keys.dart';
import 'package:argo/core/settings/settings_service.dart';
import 'package:argo/core/settings/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'resize during a preference save sends the latest viewport afterward',
    () async {
      final store = _Store();
      final settings = await SettingsService.load(
        schema: AppSettingKeys.createSchema(),
        store: store,
      );
      final backend = _Backend();
      final service = ProjectionSettingsService(
        settings: settings,
        requested: ProjectionPreferences.defaults(),
        backend: backend,
      );
      addTearDown(() async {
        if (!backend.release.isCompleted) backend.release.complete();
        await service.close();
        await settings.close();
      });
      service.setViewport(800, 498, 48);
      final update = service.update(service.requested.copyWith(dpi: 200));
      await backend.started.future;
      final first = backend.requests.single;
      service.setViewport(600, 680, 64);
      // Let the debounce fire while saving: the newest layout must not be lost.
      await Future<void>.delayed(const Duration(milliseconds: 180));
      backend.release.complete();
      await update;
      await backend.latest.future.timeout(const Duration(seconds: 2));
      expect(backend.requests, hasLength(2));
      expect(backend.requests.last, service.effective);
      expect(backend.requests.last, isNot(first));
      expect(backend.requests.last.viewInsets.left, 323);
      expect(backend.requests.last.dpi, 138);
      expect(service.requested.dpi, 200);
      expect(settings.get(AppSettingKeys.projectionDisplayDpi), 200);
      await settings.flush();
      expect(
        store.document.values[AppSettingKeys.projectionDisplayDpi.id],
        200,
      );
      service.setViewport(double.nan, 680, 64);
      expect(service.measuredViewport, (600.0, 680.0, 64.0));
    },
  );
}

class _Store implements SettingsStore {
  SettingsDocument document = SettingsDocument();
  @override
  Future<SettingsDocument> read() async => document;
  @override
  Future<void> write(SettingsDocument document) async =>
      this.document = document;
}

class _Backend implements ProjectionConfigurationBackend {
  final requests = <ProjectionPreferences>[];
  final started = Completer<void>();
  final release = Completer<void>();
  final latest = Completer<void>();
  @override
  ProjectionConfigurationState get configuration =>
      ProjectionConfigurationState(
        capabilities: ProjectionCapabilities(
          resolutions: const [(1280, 720)],
          frameRates: const [30],
          minimumDpi: 80,
          maximumDpi: 640,
          defaults: ProjectionPreferences.defaults(),
          audio: const [],
        ),
      );
  @override
  Stream<ProjectionConfigurationState> get configurationChanges =>
      const Stream.empty();
  @override
  Future<void> requestConfiguration(ProjectionPreferences preferences) async {
    requests.add(preferences);
    if (requests.length == 1) {
      started.complete();
      await release.future;
    } else if (!latest.isCompleted) {
      latest.complete();
    }
  }
}
