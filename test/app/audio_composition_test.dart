import 'package:argo/app/audio_composition.dart';
import 'package:argo/core/audio/audio_backend.dart';
import 'package:argo/core/audio/audio_service.dart';
import 'package:argo/core/audio/in_memory_audio_backend.dart';
import 'package:argo/core/diagnostics/diagnostics_service.dart';
import 'package:argo/core/lifecycle/app_lifecycle_coordinator.dart';
import 'package:argo/core/services/service_registry.dart';
import 'package:argo/core/settings/app_setting_keys.dart';
import 'package:argo/core/settings/settings_service.dart';
import 'package:argo/core/settings/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('registers AudioService and lifecycle owns backend cleanup', () async {
    final settings = await SettingsService.load(
      schema: AppSettingKeys.createSchema(),
      store: _MemoryStore(),
    );
    final services = ServiceRegistry()..register(settings);
    final lifecycle = AppLifecycleCoordinator();
    final backend = InMemoryAudioBackend();

    final audio = await registerAudioCoreServices(
      services: services,
      lifecycle: lifecycle,
      diagnostics: DiagnosticsService(),
      backend: backend,
    );

    expect(services.get<AudioService>(), same(audio));
    expect(services.get<AudioBackend>(), same(backend));
    await lifecycle.shutdown();
    expect(backend.isClosed, isTrue);
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
