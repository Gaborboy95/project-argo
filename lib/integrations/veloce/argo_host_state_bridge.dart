import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:io';

import 'package:veloce_lua_core/veloce_lua_core.dart';

import '../../core/media/media_session_service.dart';
import '../../core/media/media_state.dart';
import '../../core/projection/projection_models.dart';
import '../../core/projection/projection_service.dart';
import '../../core/projection/projection_types.dart';

/// Cached read-only host facts. Events are public invalidations, never metadata.
final class ArgoHostStateBridge {
  ArgoHostStateBridge({this.diagnostics = false}) {
    _snapshot = _envelope(_empty());
    _semantic = jsonEncode(_empty());
  }
  final bool diagnostics;
  Timer? _logTimer;
  String? _pendingLog;
  static const readCapability = Capability('argo.host.read.v1');
  static const topic = 'argo.host.state.changed.v1';
  static CapabilityCatalog get catalog =>
      CapabilityCatalog([...BuiltInCapabilities.all, readCapability]);
  static CapabilityManager capabilityManager() => CapabilityManager(
    catalog: catalog,
    enabledCapabilities: [...BuiltInCapabilities.safeDefaults, readCapability],
  );
  static PluginLoader loader() => PluginLoader(
    manifestParser: PluginManifestParser(capabilityCatalog: catalog),
  );
  final String _epoch =
      '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
  int _revision = 0;
  late Map<String, Object?> _snapshot;
  String _semantic = '';
  PluginEventBus? _events;
  ProjectionService? _projection;
  MediaSessionService? _media;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  Timer? _notification;
  bool _closed = false;

  void register(PluginManager manager) {
    if (_events != null) throw StateError('Host API already registered');
    _events = manager.eventBus;
    if (diagnostics) {
      _subscriptions.add(
        manager.logManager.events.listen((event) {
          if (_closed ||
              event.level != PluginLogLevel.debug ||
              !manager.currentPlugins.any(
                (p) =>
                    p.manifest.id == event.pluginId &&
                    p.manifest.permissions.contains(readCapability),
              )) {
            return;
          }
          final message = event.message.length > 1024
              ? event.message.substring(0, 1024)
              : event.message;
          _pendingLog =
              '[Argo host observer ${event.pluginId}] ${jsonEncode(message)}';
          _logTimer ??= Timer(const Duration(seconds: 3), () {
            _logTimer = null;
            if (!_closed && _pendingLog != null) stdout.writeln(_pendingLog);
            _pendingLog = null;
          });
        }),
      );
    }
    // Extend the manager's own registry: retain its generation-aware checker.
    manager.apiRegistry.registerNamespace(
      PluginApiNamespace(
        name: 'argo_host',
        methods: {
          'snapshot': PluginApiMethod(
            capability: readCapability,
            handler: (call) {
              call.requireArgumentCount(0);
              return _snapshot; // registry normalizes/copies structured values before returning
            },
          ),
        },
      ),
    );
  }

  void attach(ProjectionService projection, MediaSessionService media) {
    if (_closed || _projection != null) {
      throw StateError('Host provider already attached/closed');
    }
    _projection = projection;
    _media = media;
    _subscriptions.add(projection.changes.listen((_) => _refresh()));
    _subscriptions.add(media.changes.listen((_) => _refresh()));
    _refresh(); // subscribe before current read; covers already-running sessions
  }

  static Map<String, Object?> _empty() => {
    'available': false,
    'projection': {'activeSessionId': null, 'sessions': <Object?>[]},
    'media': {'activeSourceId': null, 'sources': <Object?>[]},
    'phones': <Object?>[],
  };
  Map<String, Object?> _envelope(Map<String, Object?> value) => {
    'schemaVersion': 1,
    'epoch': _epoch,
    'revision': _revision,
    'updatedAtMs': DateTime.now().toUtc().millisecondsSinceEpoch,
    ...value,
  };
  void _refresh() {
    if (_closed) return;
    final p = _projection!.current, m = _media!.current;
    final live = p.backendAvailable
        ? p.sessions
              .where(
                (s) =>
                    s.state != ProjectionSessionState.failed &&
                    s.state != ProjectionSessionState.disconnected,
              )
              .toList()
        : <ProjectionSession>[];
    // Never expose cached metadata for a removed/replaced projection session,
    // even if its separate media notification has not reached this listener yet.
    final sources = m.sources
        .where(
          (source) => live.any(
            (session) =>
                session.id == source.sessionId &&
                session.device.id == source.deviceId,
          ),
        )
        .toList();
    final selected = sources.any((source) => source.id == m.activeSourceId)
        ? m.activeSourceId
        : null;
    final value = <String, Object?>{
      'available': p.backendAvailable,
      'projection': {
        'activeSessionId': live.any((s) => s.id == p.activeSessionId)
            ? p.activeSessionId
            : null,
        'sessions': [
          for (final s in live)
            {
              'sessionId': s.id,
              'deviceId': s.device.id,
              'protocol': s.device.protocol.name,
              'transport': s.device.transport.name,
              'state': s.state.name,
              'deviceName':
                  s.metadata?.phone.displayName ?? s.device.displayName,
              'manufacturer': s.metadata?.phone.manufacturer,
              'model': s.metadata?.phone.model,
            },
        ],
      },
      'media': {
        'activeSourceId': selected,
        'sources': [
          for (final source in sources)
            {
              'sourceId': source.id,
              'sourceKind': source.kind.name,
              'sessionId': source.sessionId,
              'deviceId': source.deviceId,
              'revision': source.revision,
              'updatedAtMs': source.updatedAtMs,
              ...mediaFields(source.details),
            },
        ],
      },
      'phones': [
        for (final s in live)
          {
            'sessionId': s.id,
            'deviceId': s.device.id,
            'batteryPercent': s.metadata?.phone.batteryPercent,
            'criticalBattery': s.metadata?.phone.criticalBattery,
            'charging': null,
            'revision': s.metadata?.revision,
            'updatedAtMs': (s.metadata?.updatedAtMs ?? 0) == 0
                ? null
                : s.metadata?.updatedAtMs,
          },
      ],
    };
    final semantic = jsonEncode(value);
    if (semantic == _semantic) return;
    _semantic = semantic;
    _revision++;
    _snapshot = _envelope(value);
    // Cached reads update immediately; one timer coalesces invalidations at 4 Hz.
    _notification ??= Timer(const Duration(milliseconds: 250), () {
      _notification = null;
      if (!_closed) _events?.publish(topic, const <String, Object?>{});
    });
  }

  static Map<String, Object?> mediaFields(MediaDetails d) => {
    'title': d.title,
    'artist': d.artist,
    'album': d.album,
    'application': d.application,
    'playbackState': d.playback.name,
    'positionMs': d.positionMs,
    'durationMs': d.durationMs,
  };
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _notification?.cancel();
    _logTimer?.cancel();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _revision++;
    _snapshot = _envelope(_empty());
  }
}
