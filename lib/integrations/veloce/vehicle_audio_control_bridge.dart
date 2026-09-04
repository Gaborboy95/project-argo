import 'dart:io';

import 'package:veloce_lua_core/veloce_lua_core.dart';

import '../../core/audio/audio_service.dart';
import '../../core/diagnostics/diagnostics_service.dart';
import 'vehicle_integration_plugin_authorizer.dart';

/// Admits only fixed audio commands from the selected vehicle integration.
final class VehicleAudioControlBridge {
  VehicleAudioControlBridge._({
    required this.audio,
    required this.authorizer,
    required this.diagnostics,
  });

  static const volumeUpTopic = 'audio.command.volume.up';
  static const volumeDownTopic = 'audio.command.volume.down';
  static const muteToggleTopic = 'audio.command.mute.toggle';
  static const sourceNextTopic = 'audio.command.source.next';
  static const sourcePreviousTopic = 'audio.command.source.previous';
  static const _ownerId = 'argo.vehicle-audio-control-bridge';

  static Future<VehicleAudioControlBridge> start({
    required PluginEventBus eventBus,
    required PluginRegistry pluginRegistry,
    required VelocePluginLoadedLookup isPluginLoaded,
    required Directory? activeIntegrationPluginRoot,
    required AudioService audio,
    required DiagnosticsService diagnostics,
  }) async {
    final bridge = VehicleAudioControlBridge._(
      audio: audio,
      authorizer: await VehicleIntegrationPluginAuthorizer.create(
        pluginRegistry: pluginRegistry,
        isPluginLoaded: isPluginLoaded,
        activeIntegrationPluginRoot: activeIntegrationPluginRoot,
        diagnostics: diagnostics,
      ),
      diagnostics: diagnostics,
    );
    try {
      bridge._subscribe(eventBus);
      return bridge;
    } on Object catch (error, stackTrace) {
      await bridge.close();
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  final AudioService audio;
  final VehicleIntegrationPluginAuthorizer authorizer;
  final DiagnosticsService diagnostics;
  final List<PluginEventSubscription> _subscriptions = [];
  Future<void>? _closeFuture;
  var _closed = false;

  void _subscribe(PluginEventBus bus) {
    void bind(String topic, Future<void> Function() command) {
      _subscriptions.add(
        bus.subscribe(
          ownerId: _ownerId,
          topic: topic,
          handler: (event) => _handle(event, command),
        ),
      );
    }

    bind(volumeUpTopic, () => audio.volumeStep(AudioVolumeDirection.up));
    bind(volumeDownTopic, () => audio.volumeStep(AudioVolumeDirection.down));
    bind(muteToggleTopic, audio.toggleMuted);
    bind(sourceNextTopic, audio.selectNextSource);
    bind(sourcePreviousTopic, audio.selectPreviousSource);
  }

  Future<void> _handle(
    PluginEvent event,
    Future<void> Function() command,
  ) async {
    if (_closed) return;
    final pluginId = event.sourcePluginId;
    if (pluginId == null) {
      diagnostics.warning(
        'audio.vehicle-control',
        'Vehicle audio command rejected: anonymous event.',
      );
      return;
    }
    if (!await authorizer.allows(pluginId)) {
      diagnostics.warning(
        'audio.vehicle-control',
        'Vehicle audio command rejected: unauthorized plugin $pluginId.',
      );
      return;
    }
    if (_closed) return;
    try {
      await command();
      diagnostics.info(
        'audio.vehicle-control',
        'Vehicle audio command ${event.topic} accepted from $pluginId.',
      );
    } on Object catch (error, stackTrace) {
      diagnostics.error(
        'audio.vehicle-control',
        'Vehicle audio command ${event.topic} failed.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closed = true;
    Object? firstError;
    StackTrace? firstStackTrace;
    for (final subscription in _subscriptions) {
      try {
        await subscription.cancel();
      } on Object catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    _subscriptions.clear();
    if (firstError case final error?) {
      Error.throwWithStackTrace(error, firstStackTrace!);
    }
  }
}
