import 'dart:async';
import 'dart:convert';

import '../projection/carplay_settings_service.dart';
import '../projection/projection_models.dart';
import '../projection/projection_service.dart';
import '../projection/projection_types.dart';
import '../settings/app_setting_keys.dart';
import '../settings/settings_service.dart';
import 'connectivity_service.dart';
import 'device_hub_models.dart';

/// The application owns one selected phone, regardless of its transport.
/// Widgets display this inventory; they never start protocol receivers.
class DeviceConnectionService {
  DeviceConnectionService({
    required this.backend,
    required this.projection,
    required this.settings,
    this.carPlay,
    this.startupWindow = const Duration(seconds: 90),
    this.operationTimeout = const Duration(seconds: 35),
  }) {
    _selectedId = settings.get(AppSettingKeys.selectedDevice);
    try {
      final stored = jsonDecode(settings.get(AppSettingKeys.deviceInventory));
      if (stored is List && stored.length <= 64) {
        for (final value in stored) {
          final phone = RememberedPhone.fromJson(value as Map<String, dynamic>);
          _remembered[phone.id] = phone;
        }
      }
    } on Object {
      // A damaged cache never changes BlueZ bonds or starts an unknown phone.
    }
    _subscriptions.add(
      backend.connectivityChanges.listen(
        (_) => _observerRestored('Bluetooth'),
        onError: (Object _) => _observerFailed('Bluetooth'),
      ),
    );
    _subscriptions.add(
      projection.changes.listen(
        (_) => _observerRestored('Projection'),
        onError: (Object _) => _observerFailed('Projection'),
      ),
    );
    final cp = carPlay;
    if (cp != null) {
      _subscriptions.add(
        cp.changes.listen(
          (_) => _observerRestored('CarPlay'),
          onError: (Object _) => _observerFailed('CarPlay'),
        ),
      );
    }
    _subscriptions.add(
      settings.changes.listen((change) {
        if (change.keyId == AppSettingKeys.autoConnectPhone.id) {
          if (!autoConnect) _cancelStartup();
          _notify();
        }
      }),
    );
    _startupTimer = Timer(startupWindow, _cancelStartup);
    _reconcile();
  }

  final ConnectivityService backend;
  final ProjectionService projection;
  final SettingsService settings;
  final CarPlaySettingsService? carPlay;
  final Duration startupWindow, operationTimeout;
  final _changes = StreamController<void>.broadcast(sync: true);
  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _remembered = <String, RememberedPhone>{};
  final _forgotten = <String>{};
  final _pairingKnown = <String>{};
  final _seenSessions = <String>{};
  final _pendingIncoming = <String>{};
  final _unavailableSources = <String>{};
  List<DeviceHubDevice> _devices = const [];
  List<DeviceHubDevice> get devices => _devices;
  Stream<void> get changes => _changes.stream;
  ConnectivitySnapshot get connectivity => backend.connectivity;
  String get selectedId => _selectedId;
  bool get autoConnect => settings.get(AppSettingKeys.autoConnectPhone);
  bool get carPlayAvailable => carPlay?.available == true;
  bool busy = false;
  String? error;
  ProjectionProtocol? pairingProtocol;
  String _selectedId = '';
  String? _requestingId;
  String? _pairedAndroidId;
  bool _closed = false, _startupConsumed = false, _reconciling = false;
  bool _exiting = false;
  int _intent = 0;
  Timer? _startupTimer;
  Future<void> _tail = Future.value();
  Future<void>? _persisting;

  static const _activeAa = {
    'preparing',
    'bootstrap',
    'connecting',
    'connected',
    'projecting',
    'streaming',
    'suspended',
    'backoff',
    'retrying',
    'cleanup',
  };
  static bool _live(ProjectionSession session) =>
      session.state != ProjectionSessionState.disconnected &&
      session.state != ProjectionSessionState.failed;

  void _notify() {
    if (!_closed) _changes.add(null);
  }

  void _cancelStartup() {
    _startupConsumed = true;
    _startupTimer?.cancel();
  }

  void _observerFailed(String source) {
    if (_closed) return;
    _unavailableSources.add(source);
    _cancelStartup();
    ++_intent;
    error = 'Device status is temporarily unavailable.';
    _notify();
  }

  void _observerRestored(String source) {
    _unavailableSources.remove(source);
    if (_unavailableSources.isEmpty &&
        error == 'Device status is temporarily unavailable.') {
      error = null;
    }
    _reconcile();
  }

  void _reconcile() {
    if (_closed || _reconciling) return;
    _reconciling = true;
    try {
      _refreshInventory();
      for (final device in _devices) {
        if (!device.paired && device.sessions.isEmpty) continue;
        if (!_remembered.containsKey(device.id) && _remembered.length >= 64) {
          continue;
        }
        final previous = _remembered[device.id];
        final bindings = <ProjectionProtocol, Set<String>>{
          for (final entry
              in previous?.projectionIds.entries ??
                  const <MapEntry<ProjectionProtocol, Set<String>>>[])
            entry.key: {...entry.value},
        };
        for (final session in device.sessions.where(_live)) {
          final ids = bindings.putIfAbsent(session.device.protocol, () => {});
          ids.add(session.device.id);
          while (ids.length > 32) {
            ids.remove(ids.first);
          }
        }
        _remembered[device.id] = RememberedPhone(
          id: device.id,
          name: device.name,
          address: device.bluetoothAddress,
          protocol: device.protocol,
          bluetoothOnly:
              previous?.bluetoothOnly == true && !device.sessions.any(_live),
          projectionIds: bindings,
        );
      }
      final cpAddress = bluetoothAddress(
        carPlay?.current['target'] as String? ?? '',
      );
      final pairedDevice = pairingProtocol == ProjectionProtocol.carPlay
          ? _devices
                .where(
                  (d) => cpAddress != null && d.bluetoothAddress == cpAddress,
                )
                .firstOrNull
          : pairingProtocol == ProjectionProtocol.androidAuto
          ? _devices
                .where(
                  (d) =>
                      d.paired &&
                      !_pairingKnown.contains(d.id) &&
                      d.protocol != ProjectionProtocol.carPlay,
                )
                .firstOrNull
          : null;
      if (!_exiting && pairedDevice != null) {
        final addingAndroid = pairingProtocol == ProjectionProtocol.androidAuto;
        final previous = _remembered[pairedDevice.id];
        _remembered[pairedDevice.id] = RememberedPhone(
          id: pairedDevice.id,
          name: pairedDevice.name,
          address: pairedDevice.bluetoothAddress,
          protocol: pairedDevice.protocol ?? pairingProtocol,
          projectionIds: previous?.projectionIds ?? {},
        );
        _selectedId = pairedDevice.id;
        _requestingId = pairedDevice.id;
        pairingProtocol = null;
        if (addingAndroid) _pairedAndroidId = pairedDevice.id;
        unawaited(
          settings
              .set(AppSettingKeys.selectedDevice, _selectedId)
              .catchError((Object _) {}),
        );
      }
      // Migrate the old AA selection once; no second protocol is inferred.
      if (_selectedId.isEmpty) {
        final old = settings.get(AppSettingKeys.connectivityPhone);
        final address = bluetoothAddress(old.split('/').last);
        final candidate = _devices
            .where((d) => d.bluetoothAddress == address && d.protocol != null)
            .firstOrNull;
        if (address != null && candidate != null) {
          _selectedId = candidate.id;
          unawaited(
            settings
                .set(AppSettingKeys.selectedDevice, candidate.id)
                .catchError((Object _) {}),
          );
        }
      }
      _schedulePersist();
      _refreshInventory();
    } finally {
      _reconciling = false;
    }
    _notify();
    final pairedAndroid = _pairedAndroidId;
    _pairedAndroidId = null;
    if (!_exiting && pairedAndroid != null) {
      final intent = _intent;
      unawaited(_enqueue(() => _connect(pairedAndroid, intent)));
    }
    _maybeStartup();
    _incomingSession();
  }

  void _refreshInventory() {
    final requested = _devices.where((d) => d.id == _requestingId).firstOrNull;
    final target = carPlay?.current['target'] as String? ?? '';
    _devices = buildDeviceInventory(
      connectivity,
      projection.current,
      remembered: _remembered.values.toList(),
      selectedId: _selectedId,
      carPlayRunning: carPlay?.current['running'] == true,
      carPlayTarget: target.isNotEmpty
          ? target
          : requested?.protocol == ProjectionProtocol.carPlay
          ? requested!.id
          : '',
    ).where((d) => !_forgotten.contains(d.id)).toList(growable: false);
  }

  void _incomingSession() {
    if (_exiting) return;
    final live = projection.current.sessions.where(_live).toList();
    final fresh = live.where((s) => !_seenSessions.contains(s.id)).toList();
    _pendingIncoming.addAll(fresh.map((s) => s.id));
    _pendingIncoming.removeWhere((id) => !live.any((s) => s.id == id));
    _seenSessions
      ..clear()
      ..addAll(live.map((s) => s.id));
    if (busy || _pendingIncoming.isEmpty) return;
    final session = live.lastWhere((s) => _pendingIncoming.contains(s.id));
    _pendingIncoming.clear();
    final device = _devices
        .where((d) => d.sessions.any((s) => s.id == session.id))
        .firstOrNull;
    if (device == null || device.id == _selectedId) return;
    _cancelStartup();
    final intent = ++_intent;
    unawaited(
      _enqueue(() async {
        _check(intent);
        if (session.device.protocol == ProjectionProtocol.carPlay) {
          await _stopAndroidAuto();
        } else {
          await _stopCarPlay();
        }
        _check(intent);
        await _select(device.id);
        _requestingId = device.id;
      }),
    );
  }

  void _schedulePersist() {
    if (_persisting != null || _closed) return;
    _persisting =
        Future<void>(() async {
              while (!_closed) {
                final entries = _remembered.values.toList()
                  ..sort((a, b) => a.id.compareTo(b.id));
                final json = jsonEncode(
                  entries.map((p) => p.toJson()).toList(),
                );
                if (json == settings.get(AppSettingKeys.deviceInventory)) {
                  return;
                }
                await settings.set(AppSettingKeys.deviceInventory, json);
              }
            })
            .catchError((Object _) {
              if (!_closed) {
                error = 'Could not save remembered devices.';
                _notify();
              }
            })
            .whenComplete(() => _persisting = null);
  }

  DeviceHubDevice _device(String id) =>
      _devices.where((d) => d.id == id).firstOrNull ??
      (throw StateError('This device is no longer available.'));

  ProjectionDevice? _usbDevice(DeviceHubDevice row) {
    final bindings = _remembered[row.id]?.projectionIds;
    for (final candidate in projection.current.devices) {
      if (candidate.transport != ProjectionTransport.usb ||
          candidate.protocol != row.protocol) {
        continue;
      }
      if (row.id == 'projection:${candidate.protocol.name}:${candidate.id}') {
        return candidate;
      }
      final aliases = projectionDeviceIdentities(candidate);
      if (bindings?[candidate.protocol]?.any((id) => aliases.contains(id)) ==
          true) {
        return candidate;
      }
    }
    return null;
  }

  void _maybeStartup() {
    if (_startupConsumed || _closed || _exiting || busy || !autoConnect) return;
    final selected = _devices.where((d) => d.id == _selectedId).firstOrNull;
    if (selected == null || selected.protocol == null) return;
    final ready = switch (selected.protocol!) {
      ProjectionProtocol.carPlay =>
        carPlayAvailable && carPlay!.current['settings']?['enabled'] == true,
      ProjectionProtocol.androidAuto =>
        connectivity.daemonConnected &&
            connectivity.available &&
            connectivity.enabled &&
            connectivity.wirelessAvailable == true &&
            selected.endpoints.any((d) => d.paired),
    };
    if (!ready) return;
    _cancelStartup();
    final intent = ++_intent;
    unawaited(_enqueue(() => _connect(selected.id, intent)));
  }

  Future<void> _enqueue(Future<void> Function() action) {
    final operation = _tail.then((_) async {
      if (_closed) return;
      if (_exiting) return;
      busy = true;
      error = null;
      _notify();
      try {
        await action();
      } on _Superseded {
        // New device/disconnect intent owns the queued replacement.
      } on Object catch (cause) {
        if (!_closed) error = '$cause'.replaceFirst('Bad state: ', '');
      } finally {
        busy = _exiting;
        _reconcile();
      }
    });
    _tail = operation.catchError((Object _) {});
    return operation;
  }

  void _check(int intent) {
    if (_closed || _exiting || intent != _intent) throw const _Superseded();
  }

  Future<void> _wait(bool Function() ready, {int? intent}) async {
    void checkIntent() {
      if (intent != null) _check(intent);
    }

    checkIntent();
    if (ready()) return;
    final done = Completer<void>();
    void check() {
      if (done.isCompleted) return;
      try {
        checkIntent();
        if (_closed) throw const _Superseded();
        if (ready()) done.complete();
      } on Object catch (cause, stack) {
        done.completeError(cause, stack);
      }
    }

    final subscription = changes.listen((_) => check());
    final deadline = Timer(operationTimeout, () {
      if (!done.isCompleted) {
        done.completeError(
          TimeoutException(
            'The previous connection has not finished. Try again.',
          ),
        );
      }
    });
    check();
    try {
      await done.future;
    } finally {
      deadline.cancel();
      await subscription.cancel();
    }
  }

  Future<void> _cpCommand(Future<void> Function() action) async {
    final cp = carPlay;
    if (cp == null || !cp.available) {
      throw StateError('CarPlay receiver is unavailable.');
    }
    await action();
    await cp.refresh();
    if (cp.failure != null) throw StateError(cp.failure!.summary);
  }

  Future<void> _stopCarPlay() async {
    final cp = carPlay;
    if (cp == null || (!cp.available && cp.current.isEmpty)) return;
    if (cp.current['running'] == false &&
        cp.current['phase'] == 'Disconnected') {
      return;
    }
    if (!cp.available) {
      throw StateError('CarPlay cleanup could not be confirmed.');
    }
    if (cp.current['running'] == true) await _cpCommand(cp.disconnect);
    await _wait(
      () =>
          cp.current['running'] == false &&
          cp.current['phase'] == 'Disconnected',
    );
  }

  Future<void> _stopAndroidAuto() async {
    if (connectivity.cleanupError.isNotEmpty) {
      throw StateError(connectivity.cleanupError);
    }
    if (_activeAa.contains(connectivity.phase)) {
      await backend.connectivityCommand('disconnect');
      await _wait(() => !_activeAa.contains(connectivity.phase));
      if (connectivity.cleanupError.isNotEmpty) {
        throw StateError(connectivity.cleanupError);
      }
    }
    for (final session
        in projection.current.sessions
            .where(
              (s) =>
                  _live(s) &&
                  s.device.protocol == ProjectionProtocol.androidAuto,
            )
            .toList()) {
      await projection.disconnect(session.id);
      await _wait(
        () => !projection.current.sessions.any(
          (s) => s.id == session.id && _live(s),
        ),
      );
    }
  }

  Future<void> _stopDiscovery() async {
    if (!connectivity.discovering) return;
    await backend.connectivityCommand('discover', accept: false);
    await _wait(() => !connectivity.discovering);
  }

  Future<void> _select(String id) async {
    _selectedId = id;
    await settings.set(AppSettingKeys.selectedDevice, id);
    _reconcile();
  }

  Future<void> connect(String id) {
    _cancelStartup();
    final intent = ++_intent;
    _notify();
    return _enqueue(() => _connect(id, intent));
  }

  Future<void> _connect(String id, int intent) async {
    _check(intent);
    if (_unavailableSources.isNotEmpty) {
      throw StateError('Device status is temporarily unavailable.');
    }
    var device = _device(id);
    if (device.protocol == null && !device.bluetoothOnly) {
      throw StateError('Choose this phone’s connection type in Devices first.');
    }
    final liveSession = device.sessions.any(_live);
    if (!liveSession &&
        device.protocol == ProjectionProtocol.carPlay &&
        (!carPlayAvailable ||
            carPlay?.current['settings']?['enabled'] != true)) {
      throw StateError('Enable CarPlay in its settings first.');
    }
    if (!liveSession &&
        device.protocol == ProjectionProtocol.androidAuto &&
        device.endpoints.isNotEmpty &&
        (!connectivity.enabled || connectivity.wirelessAvailable != true)) {
      throw StateError('Enable wireless Android Auto in its settings first.');
    }
    await _select(id);
    _check(intent);
    if (device.sessions.any(
      (s) => _live(s) && s.state != ProjectionSessionState.connecting,
    )) {
      if (device.protocol == ProjectionProtocol.carPlay) {
        await _stopAndroidAuto();
      } else {
        await _stopCarPlay();
      }
      return;
    }
    _requestingId = id;
    pairingProtocol = null;
    await _stopCarPlay();
    await _stopAndroidAuto();
    await _stopDiscovery();
    _check(intent);
    for (final other
        in _devices
            .where((d) => d.id != id && d.protocol != null && d.connected)
            .toList()) {
      for (final endpoint in other.endpoints) {
        await backend.connectivityCommand(
          'deviceDisconnect',
          target: endpoint.id,
        );
      }
      await _wait(
        () => !_devices.any((d) => d.id == other.id && d.connected),
        intent: intent,
      );
    }
    device = _device(id);
    final protocol = device.protocol;
    if (protocol == ProjectionProtocol.carPlay) {
      final cp = carPlay;
      if (cp == null || cp.current['settings']?['enabled'] != true) {
        throw StateError('Enable CarPlay in its settings first.');
      }
      final address = cp.current['settings']?['transport'] == 'wireless'
          ? device.bluetoothAddress
          : null;
      _check(intent);
      await _cpCommand(
        address == null ? cp.connect : () => cp.connectDevice(address),
      );
      await _wait(
        () =>
            cp.current['running'] == true &&
            (address == null || cp.current['target'] == address),
        intent: intent,
      );
    } else if (protocol == ProjectionProtocol.androidAuto) {
      final endpoint =
          device.forAdapter(connectivity.adapter) ??
          device.endpoints.where((d) => d.paired).firstOrNull;
      if (endpoint == null) {
        final usb = _usbDevice(device);
        if (usb != null) {
          await projection.connect(usb.id);
          return;
        }
        throw StateError('The phone’s Bluetooth pairing is unavailable.');
      }
      if (!connectivity.enabled || connectivity.wirelessAvailable != true) {
        throw StateError('Enable wireless Android Auto in its settings first.');
      }
      if (endpoint.adapterId != connectivity.adapter) {
        await backend.connectivityCommand(
          'adapter',
          target: endpoint.adapterId,
        );
        await _wait(
          () => connectivity.adapter == endpoint.adapterId,
          intent: intent,
        );
      }
      await backend.connectivityCommand('select', target: endpoint.id);
      await _wait(() => connectivity.selected == endpoint.id, intent: intent);
      _check(intent);
      await backend.connectivityCommand('connect', target: endpoint.id);
      await _wait(
        () =>
            _activeAa.contains(connectivity.phase) ||
            connectivity.phase == 'failed',
        intent: intent,
      );
      if (connectivity.phase == 'failed') throw StateError(connectivity.detail);
    } else {
      if (!device.bluetoothOnly) {
        throw StateError(
          'Choose this phone’s connection type in Devices first.',
        );
      }
      final endpoint = device.endpoints.where((d) => d.paired).firstOrNull;
      if (endpoint == null) throw StateError('Pair this device first.');
      await backend.connectivityCommand('deviceConnect', target: endpoint.id);
      await _wait(() => _device(id).connected, intent: intent);
    }
  }

  Future<void> disconnect(String id) {
    _cancelStartup();
    ++_intent;
    _notify();
    return _enqueue(() => _disconnectDevice(id));
  }

  Future<void> _disconnectDevice(String id) async {
    final device = _device(id);
    final target = carPlay?.current['target'] as String? ?? '';
    final ownsCarPlay =
        device.sessions.any(
          (s) => _live(s) && s.device.protocol == ProjectionProtocol.carPlay,
        ) ||
        (device.bluetoothAddress != null &&
            target == device.bluetoothAddress) ||
        (id == _requestingId && device.protocol == ProjectionProtocol.carPlay);
    final ownsAa =
        device.endpoints.any((d) => d.id == connectivity.selected) &&
            _activeAa.contains(connectivity.phase) ||
        device.sessions.any(
          (s) =>
              _live(s) && s.device.protocol == ProjectionProtocol.androidAuto,
        );
    if (ownsCarPlay) await _stopCarPlay();
    if (ownsAa) await _stopAndroidAuto();
    for (final endpoint in device.endpoints) {
      await backend.connectivityCommand(
        'deviceDisconnect',
        target: endpoint.id,
      );
    }
    if (device.endpoints.isNotEmpty) await _wait(() => !_device(id).connected);
    if (_requestingId == id) _requestingId = null;
    pairingProtocol = null;
  }

  Future<void> selectProtocol(String id, ProjectionProtocol? protocol) {
    _cancelStartup();
    return _enqueue(() async {
      final device = _device(id);
      if (device.sessions.any(_live) || device.connecting) {
        throw StateError(
          'Disconnect the device before changing its phone system.',
        );
      }
      _remembered[id] = RememberedPhone(
        id: id,
        name: device.name,
        address: device.bluetoothAddress,
        protocol: protocol,
        bluetoothOnly: protocol == null,
        projectionIds: _remembered[id]?.projectionIds ?? {},
      );
      await _select(id);
      _schedulePersist();
    });
  }

  Future<void> setAutoConnect(bool value) async {
    if (!value) _cancelStartup();
    await settings.set(AppSettingKeys.autoConnectPhone, value);
    _notify();
  }

  /// Explicit user confirmation joins a USB identity to an existing phone.
  /// No alias-based guess or radio command participates in this operation.
  Future<void> linkDevice(String usbId, String phoneId) => _enqueue(() async {
    final usb = _device(usbId);
    final phone = _device(phoneId);
    if (usbId == phoneId ||
        usb.bluetoothAddress != null ||
        phone.bluetoothAddress == null ||
        !usb.sessions.any(_live) ||
        usb.sessions.any(
          (s) => s.device.transport != ProjectionTransport.usb,
        )) {
      throw StateError(
        'Choose a connected USB phone and its saved Bluetooth device.',
      );
    }
    final bindings = <ProjectionProtocol, Set<String>>{
      for (final entry
          in _remembered[phoneId]?.projectionIds.entries ??
              const <MapEntry<ProjectionProtocol, Set<String>>>[])
        entry.key: {...entry.value},
    };
    for (final session in usb.sessions) {
      final ids = bindings.putIfAbsent(session.device.protocol, () => {});
      ids.add(session.device.id);
      while (ids.length > 32) {
        ids.remove(ids.first);
      }
    }
    _remembered[phoneId] = RememberedPhone(
      id: phoneId,
      name: phone.name,
      address: phone.bluetoothAddress,
      protocol: usb.protocol ?? phone.protocol,
      projectionIds: bindings,
    );
    _remembered.remove(usbId);
    if (_selectedId == usbId) await _select(phoneId);
    if (_requestingId == usbId) _requestingId = phoneId;
    _schedulePersist();
  });

  Future<void> beginPairing(ProjectionProtocol protocol) {
    _cancelStartup();
    final intent = ++_intent;
    _notify();
    return _enqueue(() async {
      await _stopCarPlay();
      await _stopAndroidAuto();
      await _stopDiscovery();
      _check(intent);
      _requestingId = null;
      _pairingKnown
        ..clear()
        ..addAll(_devices.where((d) => d.paired).map((d) => d.id));
      pairingProtocol = protocol;
      if (protocol == ProjectionProtocol.carPlay) {
        final cp = carPlay;
        if (cp == null || cp.current['settings']?['enabled'] != true) {
          throw StateError('Enable CarPlay in its settings first.');
        }
        _check(intent);
        await _cpCommand(cp.connect);
      } else {
        if (!connectivity.available || connectivity.adapter.isEmpty) {
          throw StateError('No Bluetooth controller is available.');
        }
        await backend.connectivityCommand('discover', accept: true);
      }
    });
  }

  Future<void> cancelPairing() {
    ++_intent;
    _notify();
    return _enqueue(() async {
      if (pairingProtocol == ProjectionProtocol.carPlay) await _stopCarPlay();
      if (connectivity.discovering) {
        await backend.connectivityCommand('discover', accept: false);
      }
      pairingProtocol = null;
    });
  }

  Future<void> pair(String id) => _enqueue(() async {
    final device = _device(id);
    final endpoint = device.forAdapter(connectivity.adapter);
    if (endpoint == null) {
      throw StateError('Choose this device’s Bluetooth controller first.');
    }
    await backend.connectivityCommand('pair', target: endpoint.id);
  });

  Future<void> forget(String id) {
    _cancelStartup();
    ++_intent;
    _notify();
    return _enqueue(() async {
      final device = _device(id);
      final pairings = device.endpoints.where((d) => d.paired).toList();
      if (device.bluetoothAddress != null && pairings.isEmpty) {
        throw StateError(
          'Connect the phone’s Bluetooth controller before removing its pairing.',
        );
      }
      // The Link controller disappears when its receiver stops. Remove its
      // bonds while the controller still exists, then finish device cleanup.
      for (final endpoint in pairings) {
        await backend.connectivityCommand('forget', target: endpoint.id);
        await _wait(
          () =>
              !connectivity.devices.any((d) => d.id == endpoint.id && d.paired),
        );
      }
      await _disconnectDevice(id);
      _forgotten.add(id);
      _remembered.remove(id);
      if (_selectedId == id) await _select('');
      _schedulePersist();
    });
  }

  Future<void> close() async {
    if (_closed) return;
    _cancelStartup();
    _closed = true;
    ++_intent;
    _changes.add(null);
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _tail;
    await _persisting;
    await _changes.close();
  }

  /// Stop pending connection intent before the daemon's exit cleanup begins.
  Future<void> prepareExit() async {
    _exiting = true;
    _cancelStartup();
    ++_intent;
    _notify();
    await _tail;
    busy = true;
    _notify();
  }
}

class _Superseded implements Exception {
  const _Superseded();
}
