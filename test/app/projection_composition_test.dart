import 'package:argo/app/projection_composition.dart';
import 'package:argo/core/audio/audio_service.dart';
import 'package:argo/core/audio/in_memory_audio_backend.dart';
import 'package:argo/core/diagnostics/diagnostics_service.dart';
import 'package:argo/core/lifecycle/app_lifecycle_coordinator.dart';
import 'package:argo/core/projection/projection_backend.dart';
import 'package:argo/core/projection/projection_service.dart';
import 'package:argo/core/services/service_registry.dart';
import 'package:argo/core/settings/app_setting_keys.dart';
import 'package:argo/core/settings/settings_service.dart';
import 'package:argo/core/settings/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('registers disabled projection and lifecycle cleans it up', () async {
    final settings = await SettingsService.load(
      schema: AppSettingKeys.createSchema(),
      store: _MemoryStore(),
    );
    final audio = await DefaultAudioService.start(
      backend: InMemoryAudioBackend(),
      settings: settings,
      diagnostics: DiagnosticsService(),
    );
    final services = ServiceRegistry()
      ..register(settings)
      ..register<AudioService>(audio);
    final lifecycle = AppLifecycleCoordinator();

    final projection = await registerProjectionServices(
      services: services,
      lifecycle: lifecycle,
      diagnostics: DiagnosticsService(),
      environment: const {},
      isLinux: false,
    );

    expect(services.get<ProjectionService>(), same(projection));
    expect(services.contains<ProjectionBackend>(), isTrue);
    await lifecycle.shutdown();
    await audio.close();
    await settings.close();
  });
}

final class _MemoryStore implements SettingsStore {
  var document = SettingsDocument();
  @override
  Future<SettingsDocument> read() async => document;
  @override
  Future<void> write(SettingsDocument document) async =>
      this.document = document;
}
