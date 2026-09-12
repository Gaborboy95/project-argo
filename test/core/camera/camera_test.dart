import 'dart:convert';
import 'dart:typed_data';

import 'package:argo/core/camera/camera_service.dart';
import 'package:argo/core/camera/native_camera_service.dart';
import 'package:argo/core/settings/app_setting_keys.dart';
import 'package:argo/core/settings/settings_service.dart';
import 'package:argo/core/settings/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

class MemoryCameraSettings implements SettingsStore {
  SettingsDocument document = SettingsDocument(values: {});
  @override
  Future<SettingsDocument> read() async => document;
  @override
  Future<void> write(SettingsDocument value) async {
    document = value;
  }
}

void main() {
  test(
    'stable role assignment survives reload; release absence is isolated',
    () async {
      final store = MemoryCameraSettings();
      final settings = await SettingsService.load(
        schema: AppSettingKeys.createSchema(),
        store: store,
      );
      await settings.set(
        AppSettingKeys.cameraRear,
        'by-path:physical-usb-port-2-video-index0',
      );
      expect(
        () => settings.set(AppSettingKeys.cameraRear, '/dev/video0'),
        throwsFormatException,
      );
      final restored = await SettingsService.load(
        schema: AppSettingKeys.createSchema(),
        store: store,
      );
      final service = NativeCameraService(
        settings: restored,
        environment: const {},
      );
      expect(
        service.current.assignments[CameraRole.rear],
        'by-path:physical-usb-port-2-video-index0',
      );
      expect(service.current.lastFrame, isNull);
      expect(service.current.sequence, 0);
      await service.initialize();
      expect(service.current.available, isFalse);
      expect(service.current.state, CameraStreamState.failed);
      expect(store.document.values.keys, contains('camera.rear'));
      expect(store.document.values.keys.where((k) => k.startsWith('camera.')), [
        'camera.rear',
      ]);
      await service.close();
      await restored.close();
      await settings.close();
    },
  );
  test('actual control decoder handles split/coalesced frames and rejects oversized data', () {
    List<int> encode(Map<String, Object?> v) {
      final bytes = utf8.encode(jsonEncode(v));
      return [
        ...(ByteData(4)..setUint32(0, bytes.length)).buffer.asUint8List(),
        ...bytes,
      ];
    }

    final bytes = [
      ...encode({'version': 1, 'state': 'stale'}),
      ...encode({'version': 1, 'state': 'disconnected'}),
    ];
    final decoder = CameraControlDecoder();
    final decoded = <Map<String, dynamic>>[];
    for (final byte in bytes) {
      decoded.addAll(decoder.add([byte]));
    }
    expect(decoded.map((v) => v['state']), ['stale', 'disconnected']);
    expect(CameraControlDecoder().add(bytes).length, 2);
    expect(
      () => CameraControlDecoder().add([0, 1, 0, 0]).toList(),
      throwsFormatException,
    );
  });
}
