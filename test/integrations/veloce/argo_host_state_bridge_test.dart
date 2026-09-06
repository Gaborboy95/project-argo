import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:argo/core/media/media_session_service.dart';
import 'package:argo/core/media/media_state.dart';
import 'package:argo/core/projection/projection_models.dart';
import 'package:argo/core/projection/projection_service.dart';
import 'package:argo/core/projection/projection_types.dart';
import 'package:argo/integrations/projection/projection_media_source.dart';
import 'package:argo/integrations/veloce/argo_host_state_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veloce_lua_core/veloce_lua_core.dart';
import 'package:veloce_lua_native/veloce_lua_native.dart';

void main() {
  final library = Platform.environment['VELOCE_LUA_LIBRARY'];
  test(
    'native Lua reads current host state, invalidations, reload, permissions and generation cleanup',
    () async {
      final root = await Directory.systemTemp.createTemp('argo-host-lua-');
      final demo = Directory(
        'tool/vehicle_integrations/example-vehicle/plugins/host_media',
      );
      for (final name in ['allowed', 'denied']) {
        final directory = Directory('${root.path}/$name');
        await directory.create();
        final manifest = jsonDecode(
          await File('${demo.path}/manifest.json').readAsString(),
        ) as Map<String, dynamic>;
        if (name == 'denied') {
          manifest['id'] = 'dev.example.denied';
          manifest['permissions'] = ['events', 'logging'];
        }
        await File('${directory.path}/manifest.json')
            .writeAsString(jsonEncode(manifest));
        await File('${directory.path}/main.lua')
            .writeAsString(await File('${demo.path}/main.lua').readAsString());
      }
      final manager = PluginManager(
        pluginRoot: root,
        runtimeFactory: IsolatedNativeLuaRuntimeFactory(libraryPath: library),
        capabilityManager: ArgoHostStateBridge.capabilityManager(),
        loader: ArgoHostStateBridge.loader(),
      );
      final bridge = ArgoHostStateBridge()..register(manager);
      final projection = _Projection();
      final media = CachedMediaSessionService();
      final source = ProjectionMediaSource(projection, media);
      addTearDown(() async {
        await bridge.close();
        await manager.close();
        await source.close();
        await media.close();
        await projection.close();
        await root.delete(recursive: true);
      });
      const id = 'dev.example.host_media';
      await manager.discover();
      expect(
        manager.pluginRegistry[id]?.state,
        PluginState.running,
        reason: manager.pluginRegistry[id]?.latestError.toString(),
      );
      expect(
        manager.pluginRegistry['dev.example.denied']?.state,
        PluginState.failed,
      );
      expect(
        manager.logManager.recent.any(
          (e) => e.pluginId == id && e.message == 'Host media unavailable',
        ),
        isTrue,
      );
      projection.emit(
        'First track',
      ); // source is already running before bridge attachment
      bridge.attach(projection, media);
      Map<String, Object?> read(String generation) =>
          manager.apiRegistry.invoke(
            PluginApiCall(
              pluginId: id,
              generation: generation,
              namespace: 'argo_host',
              method: 'snapshot',
              arguments: const [],
            ),
          ) as Map<String, Object?>;
      final generation = manager.pluginRegistry[id]!.generation!;
      final initial = read(generation);
      expect((initial['media'] as Map)['activeSourceId'], isNotNull);
      final hints = <PluginEvent>[];
      final hintSub = manager.eventBus.subscribe(
        ownerId: 'test.host.hints',
        topic: ArgoHostStateBridge.topic,
        handler: hints.add,
      );
      addTearDown(hintSub.cancel);
      projection.emit('Second track');
      projection.emit('Final track');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await manager.eventBus.flush();
      expect(hints, hasLength(1));
      expect(hints.single.data, isEmpty);
      expect(
        manager.logManager.recent.any(
          (e) => e.pluginId == id && e.message.contains('Final track'),
        ),
        isTrue,
      );
      final before = read(generation)['revision'];
      projection.emit('Final track');
      expect(read(generation)['revision'], before);
      // An untrusted event cannot replace protected host state or trigger duplicate content logging.
      final logs = manager.logManager.recent
          .where((e) => e.pluginId == id)
          .length;
      manager.eventBus.publish(ArgoHostStateBridge.topic, {'title': 'forged'});
      await manager.eventBus.flush();
      expect(
        manager.logManager.recent.where((e) => e.pluginId == id).length,
        logs,
      );
      await manager.reloadPlugin(id);
      final nextGeneration = manager.pluginRegistry[id]!.generation!;
      expect(nextGeneration, isNot(generation));
      expect(
        () => read(generation),
        throwsA(isA<StalePluginCallbackException>()),
      );
      expect(
        manager.logManager.recent.lastWhere((e) => e.pluginId == id).message,
        contains('Final track'),
      );
      final staleMedia = media.current;
      projection.emitDisconnected();
      media.replace(
        staleMedia,
      ); // delayed provider notification cannot resurrect a removed phone

      expect((read(nextGeneration)['media'] as Map)['sources'], isEmpty);
      expect(read(nextGeneration)['phones'], isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await manager.eventBus.flush();
      expect(
        manager.logManager.recent.lastWhere((e) => e.pluginId == id).message,
        'Host media disconnected',
      );
      await manager.unloadPlugin(id);
      expect(
        () => read(nextGeneration),
        throwsA(isA<StalePluginCallbackException>()),
      );
      final remainingLogs = manager.logManager.recent
          .where((e) => e.pluginId == id)
          .length;
      projection.emit('After unload');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await manager.eventBus.flush();
      expect(
        manager.logManager.recent.where((e) => e.pluginId == id).length,
        remainingLogs,
      );
    },
    skip: library == null
        ? 'Set VELOCE_LUA_LIBRARY for the native Lua exercise.'
        : false,
  );
}

final class _Projection implements ProjectionService {
  ProjectionSnapshot _current = ProjectionSnapshot(backendAvailable: false);
  final _changes = StreamController<ProjectionSnapshot>.broadcast(sync: true);
  @override
  ProjectionSnapshot get current => _current;
  @override
  Stream<ProjectionSnapshot> get changes => _changes.stream;
  void emit(String title) {
    const device = ProjectionDevice(
      id: 'synthetic-device',
      displayName: 'Synthetic phone',
      protocol: ProjectionProtocol.androidAuto,
      transport: ProjectionTransport.usb,
    );
    _current = ProjectionSnapshot(
      backendAvailable: true,
      sessions: [
        ProjectionSession(
          id: 'synthetic-session',
          device: device,
          state: ProjectionSessionState.streaming,
          metadata: ProjectionSessionMetadata(
            revision: title.hashCode & 0xffff,
            updatedAtMs: 1700000000000,
            media: MediaDetails(
              title: title,
              artist: 'Synthetic artist',
              playback: MediaPlaybackState.playing,
            ),
          ),
        ),
      ],
    );
    _changes.add(_current);
  }

  void emitDisconnected() {
    _current = ProjectionSnapshot(backendAvailable: true);
    _changes.add(_current);
  }

  @override
  Future<void> close() => _changes.close();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
